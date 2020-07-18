#!/usr/bin/env bash

set -e

function prompt {
  variable_name="${1}"
  default_value="${2}"
  echo -n "Enter ${variable_name//_/ } (${default_value}): "
  read -r temp
  if [ "${temp}" ]
  then
    eval "${variable_name}=${temp}"
  else
    eval "${variable_name}=${default_value}"
  fi
}

echo "Create a new s3 bucket for your website."
echo

project_name=
prompt "project_name" "petri-dish"
domain_root=
prompt "domain_root" "simonolander.org"
domain_name=
prompt "domain_name" "${project_name}.${domain_root}"
bucket_name=
prompt "bucket_name" "${domain_name}"
region=
prompt "region" "eu-west-3"
aws_profile=
prompt "aws_profile" "personal"

echo
echo "Is this correct?"
echo "Project name: ${project_name}"
echo "Bucket name: ${bucket_name}"
echo "Region: ${region}"
echo "AWS profile: ${aws_profile}"

echo
echo -n "Confirm (yes/no): "
read -r confirmed

if [[ "$confirmed" != "yes" ]]
then
  echo Aborted
  exit 1
fi

echo -n "Creating bucket ${bucket_name}..."
aws s3api create-bucket "--bucket=${bucket_name}" "--acl=public-read" "--region=${region}" --create-bucket-configuration "LocationConstraint=${region}" "--profile=${aws_profile}" "--output=json" > /dev/null
aws s3api wait bucket-exists "--bucket=${bucket_name}" "--profile=${aws_profile}" "--output=json" > /dev/null
aws s3api put-bucket-website "--bucket=${bucket_name}" --website-configuration "{\"IndexDocument\":{\"Suffix\":\"index.html\"}}" "--profile=${aws_profile}" "--output=json" > /dev/null
echo " done."

user_name="cicd-${project_name}"
echo -n "Creating user ${user_name}..."
aws iam create-user "--user-name=${user_name}" "--profile=${aws_profile}" "--output=json" > /dev/null
echo " done."

echo -n "Creating access key..."
access_key_json=$(aws iam create-access-key "--user-name=${user_name}" "--profile=${aws_profile}" "--output=json")
access_key_id=$(echo "${access_key_json}" | jq -re '.AccessKey.AccessKeyId')
secret_access_key=$(echo "${access_key_json}" | jq -re '.AccessKey.SecretAccessKey')
echo " done."

echo -n "Creating policies..."
policy_name="cicd-${bucket_name}"
policy_json=$(aws iam create-policy "--policy-name=${policy_name}" "--profile=${aws_profile}" "--output=json" --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:DeleteObject",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:GetObjectAcl",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": [
        "arn:aws:s3:::'"${bucket_name}"'",
        "arn:aws:s3:::'"${bucket_name}"'/*"
      ]
    }
  ]
}')
policy_arn=$(echo "${policy_json}" | jq -re '.Policy.Arn')
echo " done."

echo -n "Attaching policies..."
aws iam attach-user-policy "--policy-arn=${policy_arn}" "--user-name=${user_name}" "--profile=${aws_profile}" "--output=json"
echo " done."

echo -n "Requesting certificate..."
certificate_region="us-east-1"
certificate_json="$(aws acm request-certificate "--domain-name=${domain_name}" "--validation-method=DNS" "--region=${certificate_region}" "--profile=${aws_profile}" "--output=json")"
certificate_arn="$(echo "${certificate_json}" | jq -re .CertificateArn)"
certificate_describe_json="$(aws acm describe-certificate "--certificate-arn=${certificate_arn}" "--region=${certificate_region}" "--profile=${aws_profile}" "--output=json")"
echo " done."
echo
echo "Visit https://www.hover.com/control_panel/domain/${domain_root}/dns and create a new record with the following information."
echo "  TYPE: $(echo "${certificate_describe_json}" | jq -re '.Certificate.DomainValidationOptions[0].ResourceRecord.Type')"
echo "  HOSTNAME: $(echo "${certificate_describe_json}" | jq -re '.Certificate.DomainValidationOptions[0].ResourceRecord.Name')"
echo "  TARGET NAME: $(echo "${certificate_describe_json}" | jq -re '.Certificate.DomainValidationOptions[0].ResourceRecord.Value')"
echo
echo -n "Waiting for certificate to become validated..."
aws acm wait certificate-validated "--certificate-arn=${certificate_arn}" "--region=${certificate_region}" "--profile=${aws_profile}" "--output=json"
echo "done."
echo -n "Creating cloudfront distribution..."
caller_reference="${0}"
distribution_json="$(aws cloudfront create-distribution "--region=${certificate_region}" "--profile=${aws_profile}" "--output=json" --distribution-config '{ "CallerReference": "'"${caller_reference}"'", "Aliases": { "Quantity": 1, "Items": [ "'"${domain_name}"'" ] }, "DefaultRootObject": "index.html", "Origins": { "Quantity": 1, "Items": [ { "Id": "S3-'"${bucket_name}"'", "DomainName": "'"${bucket_name}"'.s3.amazonaws.com", "OriginPath": "", "CustomHeaders": { "Quantity": 0 }, "S3OriginConfig": { "OriginAccessIdentity": "" } } ] }, "OriginGroups": { "Quantity": 0 }, "DefaultCacheBehavior": { "TargetOriginId": "S3-'"${bucket_name}"'", "ForwardedValues": { "QueryString": false, "Cookies": { "Forward": "none" }, "Headers": { "Quantity": 0 }, "QueryStringCacheKeys": { "Quantity": 0 } }, "TrustedSigners": { "Enabled": false, "Quantity": 0 }, "ViewerProtocolPolicy": "redirect-to-https", "MinTTL": 0, "AllowedMethods": { "Quantity": 3, "Items": [ "HEAD", "GET", "OPTIONS" ], "CachedMethods": { "Quantity": 2, "Items": [ "HEAD", "GET" ] } }, "SmoothStreaming": false, "DefaultTTL": 86400, "MaxTTL": 31536000, "Compress": false, "LambdaFunctionAssociations": { "Quantity": 0 }, "FieldLevelEncryptionId": "" }, "CacheBehaviors": { "Quantity": 0 }, "CustomErrorResponses": { "Quantity": 0 }, "Comment": "", "Logging": { "Enabled": false, "IncludeCookies": false, "Bucket": "", "Prefix": "" }, "PriceClass": "PriceClass_100", "Enabled": true, "ViewerCertificate": { "ACMCertificateArn": "'"${certificate_arn}"'", "SSLSupportMethod": "sni-only", "MinimumProtocolVersion": "TLSv1.1_2016", "Certificate": "'"${certificate_arn}"'", "CertificateSource": "acm" }, "Restrictions": { "GeoRestriction": { "RestrictionType": "none", "Quantity": 0 } }, "WebACLId": "", "HttpVersion": "http2", "IsIPV6Enabled": true }')"
distribution_domain_name="$(echo "${distribution_json}" | jq -re '.Distribution.DomainName')"
echo " done."

echo "Visit https://www.hover.com/control_panel/domain/${domain_root}/dns and create a new record with the following information."
echo "  TYPE: CNAME"
echo "  HOSTNAME: ${domain_name}"
echo "  TARGET NAME: ${distribution_domain_name}"
echo
echo "Visit https://github.com/simonolander/${project_name}/settings/secrets and enter the following secrets."
echo "  AWS_ACCESS_KEY_ID: ${access_key_id}"
echo "  AWS_S3_BUCKET: ${bucket_name}"
echo "  AWS_SECRET_ACCESS_KEY: ${secret_access_key}"
