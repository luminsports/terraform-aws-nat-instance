resource "aws_security_group" "this" {
  name_prefix = var.name
  vpc_id      = var.vpc_id
  description = "Security group for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_security_group_rule" "egress" {
  security_group_id = aws_security_group.this.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
}

resource "aws_security_group_rule" "ingress_any" {
  security_group_id = aws_security_group.this.id
  type              = "ingress"
  cidr_blocks       = var.private_subnets_cidr_blocks
  from_port         = 0
  to_port           = 65535
  protocol          = "all"
}

resource "aws_network_interface" "this" {
  security_groups   = [aws_security_group.this.id]
  subnet_id         = var.public_subnet
  source_dest_check = false
  description       = "ENI for NAT instance ${var.name}"
  tags              = local.common_tags
}

resource "aws_route" "this" {
  for_each = toset(var.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.this.id
}

data "aws_ec2_instance_type" "this" {
  for_each = var.instance_types
  instance_type = each.value
}

data "aws_ami" "this" {
  most_recent = true
  owners      = ["568608671756"]

  filter {
    name   = "name"
    values = ["fck-nat-al2023-hvm-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_launch_template" "this" {
  name_prefix = var.name
  image_id    = var.image_id != "" ? var.image_id : data.aws_ami.this.id
  key_name    = var.key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  network_interfaces {
    description                 = "${var.name} ephemeral public ENI"
    subnet_id                   =  var.public_subnet
    associate_public_ip_address = true
    security_groups             = [aws_security_group.this.id]
    delete_on_termination       = true
  }

  dynamic "tag_specifications" {
    for_each = ["instance", "network-interface", "volume"]

    content {
      resource_type = tag_specifications.value

      tags          = local.common_tags
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    TERRAFORM_ENI_ID                 = aws_network_interface.this.id
    TERRAFORM_EIP_ID                 = aws_eip.nat_eip.id
  }))

  description = "Launch template for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = var.name
  desired_capacity    = var.enabled ? 1 : 0
  min_size            = var.enabled ? 1 : 0
  max_size            = 1
  health_check_type   = "EC2"
  vpc_zone_identifier = [var.public_subnet]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.use_spot_instance ? 0 : 1
      on_demand_percentage_above_base_capacity = var.use_spot_instance ? 0 : 100
      spot_allocation_strategy                 = "price-capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage       = 0
      max_healthy_percentage       = 100
      skip_matching                = true
      auto_rollback                = false
      scale_in_protected_instances = "Refresh"
    }
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = var.name
  role        = aws_iam_role.this.name
}

resource "aws_iam_role" "this" {
  name_prefix        = var.name
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  policy_arn = var.ssm_policy_arn
  role       = aws_iam_role.this.name
}

resource "aws_iam_role_policy" "eni" {
  role        = aws_iam_role.this.name
  name_prefix = var.name
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AttachNetworkInterface",
                "ec2:ModifyNetworkInterfaceAttribute",
                "ec2:DescribeInstances",
                "ec2:AssociateAddress",
                "ec2:DisassociateAddress"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_eip" "nat_eip" {
  tags = merge(var.tags, {
    "Name" = "${var.name}-eip"
  })
}
