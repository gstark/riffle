# Container image for the search Lambdas (indexer and API).
# The LanceDB native library is too large for a .zip Lambda.
# Build and push with scripts/build-search-image.sh. The Lambdas use the digest of the "latest" tag,
# so each apply after a push deploys the new image.

resource "aws_ecr_repository" "search" {
  name                 = "${var.name_prefix}-search"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "search" {
  repository = aws_ecr_repository.search.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_ecr_image" "search" {
  repository_name = aws_ecr_repository.search.name
  image_tag       = "latest"
}

locals {
  search_image_uri = "${aws_ecr_repository.search.repository_url}@${data.aws_ecr_image.search.image_digest}"
}
