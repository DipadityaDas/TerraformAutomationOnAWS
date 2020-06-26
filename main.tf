# Configure the AWS Provider
provider "aws" {
	region  = "ap-south-1"
	profile = "Dipaditya"
}

# Create a VPC in the same Availability Zone
resource "aws_vpc" "tfvpc" {
	cidr_block       = "10.0.0.0/16"
	instance_tenancy = "default"
	tags = {
		Name = "Tf-vpc"
	}
}

# Creating Internet Gateway
resource "aws_internet_gateway" "tfgateway" {
	vpc_id = aws_vpc.tfvpc.id

	tags = {
		description = "Allows connection to VPC and EC2 instance."
	}

	depends_on = [
		aws_vpc.tfvpc
	]
}

# Creating a Routing Table
resource "aws_route_table" "tfroute" {
	vpc_id = aws_vpc.tfvpc.id

	route {
		cidr_block = "0.0.0.0/0"
		gateway_id = aws_internet_gateway.tfgateway.id
	}

	tags = {
		description = "Route table for inbound traffic to vpc"
	}

	depends_on = [
		aws_internet_gateway.tfgateway
	]
}

# Creating a subnet in vpc
resource "aws_subnet" "tfsubnet" {
	vpc_id                  = aws_vpc.tfvpc.id
	availability_zone       = "ap-south-1b"
	cidr_block              = "10.0.1.0/24"
	map_public_ip_on_launch = true

	tags = {
		Name = "Tf-subnet"
	}

	depends_on = [
		aws_vpc.tfvpc
	]
}

# Creating an association between subnet and route table
resource "aws_route_table_association" "tfrouset" {
	subnet_id      = aws_subnet.tfsubnet.id
	route_table_id = aws_route_table.tfroute.id

	depends_on = [
		aws_subnet.tfsubnet,
		aws_route_table.tfroute
	]
}

# Creating a New Security Group
resource "aws_security_group" "tfsg" {
	name        = "Tf-security_group"
	description = "Allow HTTP, ssh for inbound traffic."
	vpc_id      = aws_vpc.tfvpc.id
	ingress {
		from_port   = 80
		to_port     = 80
		protocol    = "tcp"
		cidr_blocks = ["0.0.0.0/0"]
	}
	ingress {
		from_port   = 443
		to_port     = 443
		protocol    = "tcp"
		cidr_blocks = ["0.0.0.0/0"]
	}
	ingress {
		from_port   = 22
		to_port     = 22
		protocol    = "tcp"
		cidr_blocks = ["0.0.0.0/0"]
	}
	egress {
		from_port   = 0
		to_port     = 0
		protocol    = "-1"
		cidr_blocks = ["0.0.0.0/0"]
	}
	tags = {
		Name = "Tf-Firewall"
	}
	depends_on = [
		aws_route_table_association.tfrouset
	]
}

# Generating a private_key
resource "tls_private_key" "tfkey" {
	algorithm = "RSA"
	rsa_bits  = 4096
	depends_on = [
		aws_security_group.tfsg
	]
}

resource "local_file" "private-key" {
	content         = tls_private_key.tfkey.private_key_pem
	filename        = "Tfkey.pem"
}

resource "aws_key_pair" "deployer" {
	key_name   = "Tfkey"
	public_key = tls_private_key.tfkey.public_key_openssh
	depends_on = [
		tls_private_key.tfkey
	]
}

# Create an EBS Volume
resource "aws_ebs_volume" "tfebs" {
	availability_zone = aws_instance.tfos.availability_zone
	size              = 1

	tags = {
		"name" = "Tf-ebs"
	}

	depends_on = [
		aws_key_pair.deployer
	]
}

# Create an EC2 Instance
resource "aws_instance" "tfos" {
	ami                    = "ami-0447a12f28fddb066"
	instance_type          = "t2.micro"
	key_name               = aws_key_pair.deployer.key_name
	vpc_security_group_ids = ["${aws_security_group.tfsg.id}"]
	subnet_id              = aws_subnet.tfsubnet.id
	connection {
		type        = "ssh"
		user        = "ec2-user"
		private_key = tls_private_key.tfkey.private_key_pem
		host        = aws_instance.tfos.public_ip
	}
	provisioner "remote-exec" {
		inline = [
			"sudo yum install httpd php git -y",
			"sudo systemctl enable httpd",
			"sudo systemctl start httpd",
		]
	}
	tags = {
		Name = "AmazonOS"
	}
}

# Create an association between EC2 instance and EBS volume
resource "aws_volume_attachment" "ebsattach" {
	device_name = "/dev/sdf"
	volume_id   = aws_ebs_volume.tfebs.id
	instance_id = aws_instance.tfos.id
	force_detach = true
	connection {
		type        = "ssh"
		user        = "ec2-user"
		private_key = tls_private_key.tfkey.private_key_pem
		host        = aws_instance.tfos.public_ip
	}

	provisioner "remote-exec" {
		inline = [
			"sudo mkfs.ext4  /dev/xvdf",                                                     // Format
			"sudo mount  /dev/xvdf  /var/www/html",                                          // Mount
			"sudo rm -rf /var/www/html/*",                                                   // Removing all files
			"sudo git clone https://github.com/DipadityaDas/TerraformWebpage /var/www/html/" // Downloading Files
		]
	}

	depends_on = [
		aws_instance.tfos
	]
}

# Creating S3 bucket to store image
resource "aws_s3_bucket" "tfbucket" {
	bucket = "tfwebproductionbucket-v1"
	acl    = "public-read"

	tags = {
		Name = "Tf-S3-bucket"
	}

	depends_on = [
		aws_volume_attachment.ebsattach
	]
}

# Upload the image to S3 bucket
resource "aws_s3_bucket_object" "tfobject" {
	bucket       = aws_s3_bucket.tfbucket.bucket
	key          = "Profile.jpg"
	source       = "Profile.jpg"
	content_type = "image/jpg"
	acl          = "public-read"

	depends_on = [
		aws_s3_bucket.tfbucket
	]
}

# Creating a Cloud Distribution of the content
locals {
	s3_origin_id = "S3-${aws_s3_bucket.tfbucket.bucket}"
}
resource "aws_cloudfront_distribution" "tfdistribution" {
	origin {
		domain_name = aws_s3_bucket.tfbucket.bucket_domain_name
		origin_id   = local.s3_origin_id
	}
	enabled         = true
	is_ipv6_enabled = true
	default_cache_behavior {
		allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
		cached_methods   = ["GET", "HEAD"]
		target_origin_id = local.s3_origin_id
		forwarded_values {
			query_string = false
			cookies {
				forward = "none"
			}
		}
		viewer_protocol_policy = "allow-all"
		min_ttl                = 0
		default_ttl            = 120
		max_ttl                = 3600
	}
	restrictions {
		geo_restriction {
		restriction_type = "none"
		}
	}
	viewer_certificate {
		cloudfront_default_certificate = true
	}
	depends_on = [
		aws_s3_bucket_object.tfobject
	]
}

# Modification in Php Code
resource "null_resource" "tfModify" {
	connection {
		type     	= "ssh"
		user     	= "ec2-user"
		private_key = tls_private_key.tfkey.private_key_pem
		host        = aws_instance.tfos.public_ip
	}

	provisioner "remote-exec" {
		inline	= [
			"echo '<img src='https://${aws_cloudfront_distribution.tfdistribution.domain_name}/Profile.jpg' width='300' height='380'>'  | sudo tee -a /var/www/html/index.php"
		]
	}
	depends_on = [
		aws_cloudfront_distribution.tfdistribution
	]
}

# Output public ip of EC2 Instance
output "Public_IP" {
	value = "${aws_instance.tfos.public_ip}"
}

# Start in the default browser
resource "null_resource" "StartBrowsing" {
	provisioner "local-exec" {
		command = "start msedge ${aws_instance.tfos.public_ip}"
	}
	depends_on = [
		null_resource.tfModify
	]
}