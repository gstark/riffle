# Email when the sync fails. A failed run throws, so it counts in the Lambda Errors metric
# (timeouts and HistoryExpiredError too). SNS sends a confirmation email first: click the link.

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "sync_errors" {
  alarm_name          = "${local.sync_function_name}-errors"
  alarm_description   = "The Gmail sync Lambda failed in 2 of the last 3 runs."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.sync.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Also email when the sync stops running at all (for example, a broken schedule).
resource "aws_cloudwatch_metric_alarm" "sync_not_running" {
  alarm_name          = "${local.sync_function_name}-not-running"
  alarm_description   = "The Gmail sync Lambda did not run for 30 minutes."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.sync.function_name }
  statistic           = "Sum"
  period              = 1800
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Search: a message failed to index 5 times.
resource "aws_cloudwatch_metric_alarm" "index_dlq" {
  alarm_name          = "${var.name_prefix}-index-dlq"
  alarm_description   = "A message failed to index 5 times and is in the index dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.index_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Search: the indexer stopped working through the queue. The full build takes about 2 hours,
# so the limit is 3 hours.
resource "aws_cloudwatch_metric_alarm" "index_backlog" {
  alarm_name          = "${var.name_prefix}-index-backlog"
  alarm_description   = "The oldest message in the index queue is more than 3 hours old."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.index.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10800
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "indexer_errors" {
  alarm_name          = "${local.indexer_function_name}-errors"
  alarm_description   = "The search indexer Lambda failed in 2 of the last 3 five-minute periods."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.indexer.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "search_errors" {
  alarm_name          = "${local.search_function_name}-errors"
  alarm_description   = "The search API Lambda failed."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.search.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
