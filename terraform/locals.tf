# ALB and target group names are capped at 32 chars by AWS; app_name alone is
# already 33, so give resources that hit that limit a shortened prefix.
locals {
  short_name = substr(var.app_name, 0, 28)
}
