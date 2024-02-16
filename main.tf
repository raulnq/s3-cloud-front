terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.31.0"
    }
  }
  backend "local" {}
}

provider "aws" {
  region      = "<MY_REGION>"
  profile     = "<MY_AWS_PROFILE>"
  max_retries = 2
}

provider "aws" {
  alias = "acm_provider"
  region = "us-east-1"
  profile     = "<MY_AWS_PROFILE>"
}

locals {
  bucket_name             = "<MY_BUCKET_NAME>"
  hosted_zone_name        = "<MY_ROUTE53_HOSTED_ZONE_NAME>"
  certificate_domain      = "<MY_CERTIFICATE_DOMAIN>"
  sub_domain              = "<MY_SUB_DOMAIN>"
}

data "aws_route53_zone" "zone" {
  name      = local.hosted_zone_name
  private_zone = false
}

data "aws_acm_certificate" "certificate" {
  domain   = local.certificate_domain
  statuses = ["ISSUED"]
  provider = aws.acm_provider
}

resource "aws_s3_bucket" "bucket" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bucket-access-block" {
  bucket                  = aws_s3_bucket.bucket.id
  ignore_public_acls      = true
  block_public_acls       = true
  restrict_public_buckets = true
  block_public_policy     = true
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "OAC for ${local.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "bucket-policy-document" {
  statement {
    actions = ["S3:GetObject"]
    sid    = "AllowCloudFrontServicePrincipalReadOnly"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    resources = [
      "${aws_s3_bucket.bucket.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"

      values = [
        "${aws_cloudfront_distribution.s3_distribution.arn}"
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket-policy" {
  bucket = aws_s3_bucket.bucket.id
  policy = data.aws_iam_policy_document.bucket-policy-document.json
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name
    origin_id   = "origin-${local.bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "origin-${local.bucket_name}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  price_class = "PriceClass_200"
  enabled             = true
  is_ipv6_enabled     = false
  default_root_object = "index.html"

  aliases = ["${local.sub_domain}.${data.aws_route53_zone.zone.name}"]
  
  viewer_certificate {
    acm_certificate_arn            = data.aws_acm_certificate.certificate.arn
    cloudfront_default_certificate = false
    minimum_protocol_version       = "TLSv1.2_2021"
    ssl_support_method             = "sni-only"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_route53_record" "record" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "${local.sub_domain}.${data.aws_route53_zone.zone.name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_s3_object" "html-files" {
  for_each = fileset("./site/", "*.html")
  bucket = aws_s3_bucket.bucket.id
  key = each.value
  content_type    = "text/html"
  source = "./site/${each.value}"
  etag = filemd5("./site/${each.value}")
}


output "route53_name" {
  value = aws_route53_record.record.name
}

output "aws_cloudfront_distribution_domain_name" {
  value = aws_cloudfront_distribution.s3_distribution.domain_name
}
