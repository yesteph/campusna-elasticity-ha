# Make an application Highly available (50 minutes!)

In this exercise, you will deploy an Highly available application. Tha web application is PhpMyAdmin. It needs to  connect to a Relational Database Management System (RDBMS).

This RDBMS is already created with AWS Relational Database Service

You will:
* deploy an application load balancer to expose a resilient endpoint for your service
* deploy an EC2 auto scaling group to detect and replace a failing EC2 instance
* make a test of resiliency
* then you will make the RDS instance resilient by activating the automatic failover to a standby instance

The last step is to enhance the VPC itself. It has a single NAT gateway. That means if the availability zone hosting the NAT gateway goes down you will loose the Internet connectiviy for all the EC2 instances that need to access Internet. You cannot tolerate this Single Point of Failure (SPOF)!

Here is the expected result: [Schema.png](./res/schema-expected.png)

## Pre-requisites

Each participant must have a dedicated AWS account and access to the WebConsole with Administrator Access.

Inside an account, the Terraform configuration in `./terraform` must have been applied to create a VPC, subnets, route tables and a RDS instance in region `eu-west-3`.

## Understand the VPC architecture at the beginning

Connect to the [AWS WebConsole](https://aws.amazon.com/console/).
Ensure you are on the Paris region. If not, select it. 

[screenshot](./res/regions.png)

Then go to the VPC service.

You can inspect the VPC, subnets, route tables and NAT gateways created for the VPC `my-vpc`.
In particular, see the subnets - public and private - are ditributed over 2 availability zones. We will rely on this setup to get an HA application.

## Create a Load balancer

You will create an Application Load Balancer to distribute the traffic to several servers that will be spread in several availability zones.
ALB is a region scoped resource: if you configure it to use several subnets from several availability zones, it will be HA.

Go to the `EC2` service then in the left pane, click on the `Load Balancers` link and `Create Load Balancer` button.

Select `Application Load Balancer` and click on the `Create` button.

1. Enter a name: `public-alb`
2. For the scheme, indicate `Internet-facing`. This ALB will be public ; that means reachable from Internet - and so your web browser.
3. Keep IPV4 address type
4. For the network mapping:
  * Select the VPC `my-vpc`
  * Because we want a public ALB, we must select the public subnets. And because we want a to be resilient, we indicate subnets from 2 availability zones. To summarize, select the `my-vpc-public-eu-west-3a` and `my-vpc-public-eu-west-3b` subnets
5. For the security group section, you will create a new one
  * Click on the `Create a new security group` link. This will open a new tab.
  * NAme: `public-alb-sg`
  * Description: `Allow HTTP from internet``
  * VPC: ensure it is `my-vpc`
  * Add an `Inbound rule` whose type is `HTTP` and source is anywhere - 0.0.0.0/0
  * Keep the outbound rule
  * Go back to the Application Load Balancer tab and refresh the security group list. Select the newly created `public-alb-sg`
6. A load balancer can have one or more listeners to receive incoming request. Besides an ALB can have multiple target groups for each listener. In our case we will have a basic setup: one listener (HTTP) and one target group: `webservers`.
  * Click on `Create target group` button to open a new tab
  * For target type, set `Instances`
  * For the traget group name, set `webservers``
  * For the protocol and port of the target, set `HTTP:80`
  * Then you can edit the healthcheck policy. Unroll the `Advanced healthcheck settings` section to specify: protocol HTTP, 2 for `Healthy threshold`, interval to 10 seconds and path must be `/phpMyAdmin/`. The path is case-sensitive.
  * Click `Next` and `Create Target group`. Skipp the instance adding as you will do it later.
  * Go back to the Application Load Balancer tab and refresh the target group list. Select the newly created `webservers`.
7. Click on `Create load balancer`

While the load balancer is being provisionned, continue to the next section: creation of the autoscaling group.

## Create the launch template (auto scaling group)

An autoscling group needs to know the configuration (instance type, AMI, user-data) of EC2 instances it will launch. This configuration is also named `Launch template`.

On the `EC2` service page, click on `Instances / Launch Templates` link, then `Create Launch Template` button.
1. Name: `webservers`
2. AMazon Machine Image - AMI: the first `Amazon Linux 2` you get
3. Instance type: `t3.micro`
4. For the `Network settings` part, select the VPC `my-vpc` and the security group `webservers`. This security group has been created at the same time of the hands on creation.
5. For the `Advanced details` section
  * IAM insytance profile must be `ssm`
  * For the `User data` attribute, copy this script:
```sh
#!/bin/bash

# Install APACHE, PHP, mariadb, PHPMyAdmin
sudo yum update -y
sudo amazon-linux-extras install -y lamp-mariadb10.2-php7.2 php7.2  
sudo yum install -y httpd mysql  jq php-mbstring php-xml
wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz
mkdir /var/www/html/phpMyAdmin && tar -xvzf phpMyAdmin-latest-all-languages.tar.gz -C /var/www/html/phpMyAdmin --strip-components 1
rm -rf phpMyAdmin-latest-all-languages.tar.gz

# Start Apache
sudo systemctl start httpd
sudo systemctl enable httpd

# Retrieve the configuration file for phpMyAdmin. In particular the address of the RDS instance
aws secretsmanager get-secret-value --secret-id phpmyadmin_config  --region eu-west-3|jq -r '.SecretString'  > /var/www/html/phpMyAdmin/config.inc.php
```

Click on `Create Launch Template`

## Create the Auto scaling group

Now, you can - at least - create the auto scaling group.

Probably one of the most important resource for High Availability in AWS. 

It monitors health check of instances. By default it is just a connectitiy check but here, we will use the health checking from the ALB.

Furthermore, an auto scaling group distributes instances in several availabity zones.

Because the public access to our application is made via a publci laod balancer, we will create the instances in private subnets.

On the `EC2` service page, click on `AutoScaling / AutoScaling groups` link, then `Create Auto Scaling group` button.
1. Name: `webservers-asg`
2. Launch Template: `webservers``
3. Network
  * Choose the VPC `my-vpc``
  * Then the **2** private subnets
4. Load balancing: attach the auto scaling group to the `webservers` Application Load balancer. With this option, the autoscaling group will register any new instance into the Load Balancer. For the `Health check grace period`, enter 200 seconds to reduce the time of the first healtcheck after an instance launch
5.  For the `Group size`, enter min = max = desired =2. We do not want auto scaling right now.

Click on all the `Next` buttons to arrive at the summary of the configuration. 
Finally, create the autoscaling group.

Now, if you look at the autoscaling group, you will see the decisions it made in the `Activity` tab. 
Normally, you should see the creation of 2 instances.

## Correct the security groups

We have 3 security groups in this exercise.
* `public-alb-sg` which is for the Application Load balancer. It allows HTTP from Internet.
* `webservers` created with the hands on. This seurity group for the webservers has currently no rule. That means **even the healthchecks from the load balancer are not allowed!**
* `allow_sql` attached to the RDS instance. It allows all MySQL traffic

Edit the `webservers` security group and a an `Inbound rule` to  HTTP:80 from the custom source: `public-alb-sg` security group. 

You take benefit from the logical firewalling capability of security groups.

NOTE: the `allow_sql` security group allows the whole VPC CIDR as source. It works but in production you will also use logical firewalling to restrict the source to the `webservers` security group.


## Test the application

The instances must be healthy in the target group `webservers`.

If yes, you can test the acces through the load balancer.
View the ALB details and copy the `DNS name``

Open it in your web browser: `http://DNS_NAME/phpMyAdmin/`
You should arrive to phpMyAdmin application.

Login with: 
* login: `applicationuser`
* password: `a_secured_password`

You should see the list of databases available on the RDS instance.

The ALB distributes each HTTP request to an EC2 instance. It works as proxy.

## Test the resiliency

You can terminate an instance. Because the terminated instance will fail the healthcheck from the ALB, all the traffic will arrive to the remaining instance.

Because you asked a minimum of 2 in the auto scaling group size, a new instance will soon be created. Then it will be registered into the ALB and your system will go back to the normal configuration.

## Make the RDS instance highly available

The webservers are in HA but not the database. If the instance crashes, the phpMyAdmin will not be functional.

You will fix that.

Go to the `RDS` service then click on the `Databases` link.
Edit the only instance you can see to activate the `Multi AZ deployment - create a standby instance`.

Click on `Continue` button. Then check the `Apply immediately` box.
Click on `Modify DB instance`.

This takes few minutes to create a standby and replicate the (few) data. Meanwhile if you try to interact with phpMyAdmin everything should be fine.

From now, if the master of the RDS instance crash, the DNS name will be switched to the standby and this standby will be promoted new master.

## Make the VPC resilient to the lost of a NAT gateway

This step is for the ones of you who feel comfortable with the networking part.

The instructions are:
* create a new NAT gateway in the availability zone `eu-west-3b`
* create a new private route table
* For the destination `0.0.0.0/0` target the new NAT gateway
* Attach the new route table to the private subnet in availability zone `eu-west-3b`

Congratulations! You have finished this hands-on.