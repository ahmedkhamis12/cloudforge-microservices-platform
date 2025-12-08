variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment"
  type        = string
}

# S3 Bucket for static assets
resource "aws_s3_bucket" "static_assets" {
  bucket = "${var.project_name}-${var.environment}-static-assets"

  tags = {
    Name        = "${var.project_name}-static-assets"
    Environment = var.environment
  }
}

# Bucket versioning
resource "aws_s3_bucket_versioning" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket lifecycle policy
resource "aws_s3_bucket_lifecycle_configuration" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  rule {
    id     = "transition-old-versions"
    status = "Enabled"

    # Apply to entire bucket
    filter {
      prefix = ""
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }

  rule {
    id     = "delete-incomplete-uploads"
    status = "Enabled"

    # Apply to entire bucket
    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}


# # CloudFront Origin Access Identity
# resource "aws_cloudfront_origin_access_identity" "main" {
#   comment = "OAI for ${var.project_name} static assets"
# }

# # S3 bucket policy for CloudFront
# resource "aws_s3_bucket_policy" "static_assets" {
#   bucket = aws_s3_bucket.static_assets.id

#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Sid    = "AllowCloudFrontAccess"
#         Effect = "Allow"
#         Principal = {
#           AWS = aws_cloudfront_origin_access_identity.main.iam_arn
#         }
#         Action   = "s3:GetObject"
#         Resource = "${aws_s3_bucket.static_assets.arn}/*"
#       }
#     ]
#   })
# }

# # CloudFront Distribution
# resource "aws_cloudfront_distribution" "main" {
#   enabled             = true
#   is_ipv6_enabled     = true
#   comment             = "${var.project_name} static assets CDN"
#   default_root_object = "index.html"
#   price_class         = "PriceClass_100"

#   origin {
#     domain_name = aws_s3_bucket.static_assets.bucket_regional_domain_name
#     origin_id   = "S3-${aws_s3_bucket.static_assets.id}"

#     s3_origin_config {
#       origin_access_identity = aws_cloudfront_origin_access_identity.main.cloudfront_access_identity_path
#     }
#   }

#   default_cache_behavior {
#     allowed_methods  = ["GET", "HEAD", "OPTIONS"]
#     cached_methods   = ["GET", "HEAD"]
#     target_origin_id = "S3-${aws_s3_bucket.static_assets.id}"

#     forwarded_values {
#       query_string = false
#       headers      = ["Origin", "Access-Control-Request-Headers", "Access-Control-Request-Method"]

#       cookies {
#         forward = "none"
#       }
#     }

#     viewer_protocol_policy = "redirect-to-https"
#     min_ttl                = 0
#     default_ttl            = 3600
#     max_ttl                = 86400
#     compress               = true
#   }

#   restrictions {
#     geo_restriction {
#       restriction_type = "none"
#     }
#   }

#   viewer_certificate {
#     cloudfront_default_certificate = true
#   }

#   tags = {
#     Name        = "${var.project_name}-cdn"
#     Environment = var.environment
#   }
# }

# S3 Bucket for application backups
resource "aws_s3_bucket" "backups" {
  bucket = "${var.project_name}-${var.environment}-backups"

  tags = {
    Name        = "${var.project_name}-backups"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Outputs
output "static_assets_bucket_name" {
  description = "Static assets bucket name"
  value       = aws_s3_bucket.static_assets.id
}

output "static_assets_bucket_arn" {
  description = "Static assets bucket ARN"
  value       = aws_s3_bucket.static_assets.arn
}

# output "cloudfront_distribution_id" {
#   description = "CloudFront distribution ID"
#   value       = aws_cloudfront_distribution.main.id
# }

# output "cloudfront_domain_name" {
#   description = "CloudFront domain name"
#   value       = aws_cloudfront_distribution.main.domain_name
# }

output "backups_bucket_name" {
  description = "Backups bucket name"
  value       = aws_s3_bucket.backups.id
}

output "backups_bucket_arn" {
  description = "Backups bucket ARN"
  value       = aws_s3_bucket.backups.arn
}