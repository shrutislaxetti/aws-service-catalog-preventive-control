#!/bin/bash

# /*
# * Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# *
# * Permission is hereby granted, free of charge, to any person obtaining a copy of this
# * software and associated documentation files (the "Software"), to deal in the Software
# * without restriction, including without limitation the rights to use, copy, modify,
# * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# * permit persons to whom the Software is furnished to do so.
# *
# * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# */

#Initial Deployment Configuration Section
resources_cfn_stack_name="sc-product-resources"
deployment_lambda_function_name="sc-product-deployment"
deployment_lambda_role_name="sc-product-deployment-lambda-role"
# Enter the name you want to use for Amazon S3 deployment bucket
deployment_s3_bucket_name=""
product_selector_lambda_role_name="sc-product-selector-lambda-role"
resource_selector_lambda_role_name="sc-resource-selector-lambda-role"
resource_compliance_lambda_role_name="sc-resource-compliance-lambda-role"
pipeline_role_name="sc-product-update-codepipeline-role"
sc_product_policy_name="service-catalog-product-policy"
sc_portfolio_description="Security Product Allow Deploy by Developers"
sc_portfolio_name="security-products"
account_access_role_name="Admin"
account_access_user_name=""
deployer_config_file_suffix="deployer"

# check if the name of deployment S3 bucket provided in script argument
if [[ $1 != '' ]]
then
  deployment_s3_bucket_name=$1
fi

if [[ $deployment_s3_bucket_name = '' ]]
then
  echo "Usage: deploy.sh <S3 Deployment Bucket Name"
  exit 1
fi

#List of products to deploy
products_to_deploy=(sqs kinesis sns elasticsearch elasticache ebs efs dmsinstance dmsendpoint autoscaling alb albtarget alblistener fsx dynamodb sagemaker s3)

printf "Copy Deployment Files\n"
cp ../templates/deployment/*.deployer ../products-config/

printf "Create Role, Policy and SC Portfolio\n"
aws cloudformation create-stack --stack-name $resources_cfn_stack_name \
--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
--template-body file://service-catalog-product-resources-cfn.yml \
--parameters ParameterKey=PolicyName,ParameterValue=$sc_product_policy_name \
ParameterKey=DeploymentBucketName,ParameterValue=$deployment_s3_bucket_name \
ParameterKey=PortfolioDescription,ParameterValue="$sc_portfolio_description" \
ParameterKey=PortfolioName,ParameterValue=$sc_portfolio_name \
ParameterKey=AccessRoleName,ParameterValue="$account_access_role_name" \
ParameterKey=AccessUserName,ParameterValue="$account_access_user_name" \
ParameterKey=DeploymentLambdaRoleName,ParameterValue=$deployment_lambda_role_name \
ParameterKey=ProductSelectorLambdaRoleName,ParameterValue=$product_selector_lambda_role_name \
ParameterKey=ResourceComplianceLambdaRoleName,ParameterValue=$resource_compliance_lambda_role_name \
ParameterKey=ResourceSelectorLambdaRoleName,ParameterValue=$resource_selector_lambda_role_name \
ParameterKey=PipelineRoleName,ParameterValue=$pipeline_role_name

#Check if CloudFormation launch success
if [ $? -ne 0 ]
then
  printf "CFN Stack Failed to Create\n"
  exit 1
fi

printf "Waiting for CF Stack to Finish ..."
cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name --query 'Stacks[0].[StackStatus]' --output text)
while [ $cfStat != "CREATE_COMPLETE" ]
do
  sleep 5
  printf "."
  cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name --query 'Stacks[0].[StackStatus]' --output text)
  if [ $cfStat = "CREATE_FAILED" ]
  then
    printf "\nCFN Stack Failed to Create\n"
    exit 1
  fi
done

#Get Deployment Lambda IAM Role ARN
lambda_role_arn=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name \
--query 'Stacks[0].Outputs[?OutputKey==`DeploymentRoleArn`].OutputValue' \
--output text)

#Get Service Catalog IAM Policy ARN
policy_arn=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name \
--query 'Stacks[0].Outputs[?OutputKey==`PolicyArn`].OutputValue' \
--output text)

#Get Product Selector Lambda IAM Role ARN
product_selector_role_arn=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name \
--query 'Stacks[0].Outputs[?OutputKey==`ProductSelectorRoleArn`].OutputValue' \
--output text)

#Get Resource Compliance Lambda IAM Role ARN
resource_compliance_role_arn=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name \
--query 'Stacks[0].Outputs[?OutputKey==`ResourceComplianceRoleArn`].OutputValue' \
--output text)

#Get Resource Selector Lambda IAM Role ARN
resource_selector_role_arn=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name \
--query 'Stacks[0].Outputs[?OutputKey==`ResourceSelectorRoleArn`].OutputValue' \
--output text)

printf "\nCreating Deployment Lambda\n"
lambda_arn=$(aws lambda create-function --function-name $deployment_lambda_function_name --runtime python2.7 \
--role "$lambda_role_arn" --handler handler.lambda_handler --timeout 20 \
--zip-file fileb://../deployment-lambda/deployment-lambda.zip \
--environment Variables="{cfnUrl=$deployment_s3_bucket_name/deployment-cfn/sc-product-deployment.yml}" \
--publish \
--query 'FunctionArn' --output text)

aws lambda put-function-concurrency --function-name $deployment_lambda_function_name --reserved-concurrent-executions 30

#Check if Lambda created successfuly
if [ $? -ne 0 ]
then
  printf "Lambda Failed to Create\n"
  exit 1
fi

printf "Creating Product Selector Lambda\n"
product_selector_lambda_arn=$(aws lambda create-function --function-name sc-product-selector --runtime python3.6 \
--role "$product_selector_role_arn" --handler handler.lambda_handler --timeout 20 \
--zip-file fileb://../product-selector-lambda/product-selector-lambda.zip \
--query 'FunctionArn' --output text)

#Check if Lambda created successfuly
if [ $? -ne 0 ]
then
  printf "Lambda Failed to Create\n"
  exit 1
fi

printf "Creating Resource Selector Lambda\n"
resource_selector_lambda_arn=$(aws lambda create-function --function-name sc-resource-selector --runtime python3.6 \
--role "$resource_selector_role_arn" --handler handler.lambda_handler --timeout 300 --memory-size 1024 \
--zip-file fileb://../resource-selector-lambda/resource-selector-lambda.zip \
--query 'FunctionArn' --output text)

#Check if Lambda created successfuly
if [ $? -ne 0 ]
then
  printf "Lambda Failed to Create\n"
  exit 1
fi

printf "Creating Resource Compliance Lambda\n"
resource_compliance_lambda_arn=$(aws lambda create-function --function-name sc-resource-compliance --runtime python3.6 \
--role "$resource_compliance_role_arn" --handler handler.lambda_handler --timeout 300 \
--zip-file fileb://../resource-compliance-lambda/resource-compliance-lambda.zip \
--query 'FunctionArn' --output text)

#Check if Lambda created successfuly
if [ $? -ne 0 ]
then
  printf "Lambda Failed to Create\n"
  exit 1
fi

printf "Creating Deployment S3 Bucket\n"
aws cloudformation create-stack --stack-name $resources_cfn_stack_name-s3-bucket \
--template-body file://service-catalog-s3-deployment-bucket-cfn.yml  \
--tags Key=SC:Automation,Value=sc-deployment-bucket \
--parameters ParameterKey=BucketName,ParameterValue=$deployment_s3_bucket_name \
ParameterKey=LambdaArn,ParameterValue="$lambda_arn" \
ParameterKey=DeploymentConfigSuffix,ParameterValue="$deployer_config_file_suffix"

#Check if CloudFormation launch success
if [ $? -ne 0 ]
then
  printf "CFN S3 Bucket Stack Failed to Create\n"
  exit 1
fi

printf "Waiting for CF Stack to Finish ..."
cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name-s3-bucket --query 'Stacks[0].[StackStatus]' --output text)
while [ $cfStat != "CREATE_COMPLETE" ]
do
  sleep 5
  printf "."
  cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name-s3-bucket --query 'Stacks[0].[StackStatus]' --output text)
  if [ $cfStat = "CREATE_FAILED" ] || [ $cfStat =  "ROLLBACK_COMPLETE " ]
  then
    printf "\nCFN S3 Bucket Stack Failed to Create\n"
    exit 1
  fi
done

printf "\nCopy Files to S3 Bucket\n"
aws s3 cp ../s3-upload-files s3://$deployment_s3_bucket_name/ --recursive

# Wait to let deployment settle down, before deploying products to AWS Service Catalog
sleep 120

#Deploy products

#Get OS Name
getOS=$(uname -s)

# Upload Products to Service Catalog
for i in ${products_to_deploy[*]}
do
  printf "Deploying Configuration for Product: $i\n"

  if [ $getOS = "Darwin" ]
  then
    sed -i '' 's/var.deploymentBucket/'$deployment_s3_bucket_name'/g' ../products-config/sc-product-$i.deployer
    sed -i '' 's/var.portfolioCfn/'$resources_cfn_stack_name'/g' ../products-config/sc-product-$i.deployer
    sed -i '' 's/var.policy/'$sc_product_policy_name'/g' ../products-config/sc-product-$i.deployer
  else
    sed -i 's/var.deploymentBucket/'$deployment_s3_bucket_name'/g' ../products-config/sc-product-$i.deployer
    sed -i 's/var.portfolioCfn/'$resources_cfn_stack_name'/g' ../products-config/sc-product-$i.deployer
    sed -i 's/var.policy/'$sc_product_policy_name'/g' ../products-config/sc-product-$i.deployer
  fi
  aws s3 cp ../products-config/sc-product-$i.deployer s3://$deployment_s3_bucket_name/deployment-cfg/sc-product-$i.deployer
done

printf "\nSolution Deployed\n"
printf "You might check the status of each CFN directly under AWS Management Console\n"
