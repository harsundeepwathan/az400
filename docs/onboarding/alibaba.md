# Onboarding Alibaba Cloud

## 1. RAM user and policy

Create a RAM user with **programmatic access only** (no console login) and attach this
custom policy, or the system policies `AliyunECSReadOnlyAccess` and
`AliyunCloudMonitorReadOnlyAccess`:

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeInstances",
        "ecs:DescribeInstancesFullStatus",
        "ecs:DescribeRegions",
        "cms:DescribeMetricList",
        "cms:DescribeMetricLast"
      ],
      "Resource": "*"
    }
  ]
}
```

Create an AccessKey for the user. Supplying an STS `security_token` is supported, but
the token is not refreshed automatically (experimental).

## 2. Guest metrics

Basic ECS metrics (CPU, network, disk I/O) are collected by the hypervisor. Memory,
filesystem usage and load require the **CloudMonitor agent** in the instance. Without
it, Skywatch reports those metrics as unavailable.

## 3. Connect

Enter the AccessKey ID and secret, and **the regions to monitor** (for example
`cn-hongkong ap-southeast-1`). Validation calls `DescribeInstances` and
`DescribeMetricList` in every region and reports any missing action.

## Coverage
ECS discovery, status, `HealthStatus`, and CloudMonitor `acs_ecs_dashboard` metrics are
implemented. RDS, SLB, OSS and ActionTrail are **not implemented yet**.
