#!/bin/bash
# Prints the address of the hive check service in one environment.
#
#     bash infra/service-url.sh staging
#     bash infra/service-url.sh production
#
# Each environment runs one Fargate task with a public IP and no load balancer,
# so the address is that task's IP. It changes with every release, which is why
# the pipeline asks for it after each deploy instead of storing it.
#
# AWS permissions it uses: ecs:DescribeServices, ecs:ListTasks, ecs:DescribeTasks
# and ec2:DescribeNetworkInterfaces.
set -u
ENV="${1:-}"
case "$ENV" in
    staging | production) ;;
    *) echo "usage: bash infra/service-url.sh staging|production" >&2; exit 2 ;;
esac
CLUSTER="hivecheck-$ENV"
SERVICE=hivecheck-api
A="aws --region us-west-2 --output text"

# The task definition the service is rolling out, so an old task that is still
# stopping is never picked.
TD=$($A ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query "services[0].deployments[?status=='PRIMARY'] | [0].taskDefinition") || exit 1
TASKS=$($A ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING \
    --query 'taskArns') || exit 1
if [ -z "$TASKS" ] || [ "$TASKS" = None ]; then
    echo "no running task in $CLUSTER/$SERVICE" >&2
    exit 1
fi
# shellcheck disable=SC2086
ENI=$($A ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS \
    --query "tasks[?taskDefinitionArn=='$TD' && lastStatus=='RUNNING'] | [0].attachments[0].details[?name=='networkInterfaceId'] | [0].value") || exit 1
if [ -z "$ENI" ] || [ "$ENI" = None ]; then
    echo "no running task of $TD in $CLUSTER/$SERVICE yet" >&2
    exit 1
fi
IP=$($A ec2 describe-network-interfaces --network-interface-ids "$ENI" \
    --query 'NetworkInterfaces[0].Association.PublicIp') || exit 1
if [ -z "$IP" ] || [ "$IP" = None ]; then
    echo "the task in $CLUSTER/$SERVICE has no public IP" >&2
    exit 1
fi
echo "http://$IP:8000"
