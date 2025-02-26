data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.10.0"

  name = var.vpc_name
  cidr = var.vpc_cidr
  azs  = [data.aws_availability_zones.available.zone_ids[0], data.aws_availability_zones.available.zone_ids[1]]

  private_subnets = local.subnets[0]
  public_subnets  = local.subnets[1]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_suffix  = "public-subnet"
  private_subnet_suffix = "private-subnet"
}