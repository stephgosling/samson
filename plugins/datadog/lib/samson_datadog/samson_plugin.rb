# frozen_string_literal: true
module SamsonDatadog
  class Engine < Rails::Engine
  end

  class << self
    def send_notification(deploy, **kwargs)
      if deploy.stage.datadog_tags.present?
        DatadogNotification.new(deploy).deliver(**kwargs)
      end
    end

    def store_validation_monitors(deploy)
      deploy.datadog_monitors_for_validation =
        deploy.stage.datadog_monitor_queries.
          select(&:failure_behavior?).
          flat_map(&:monitors).
          reject { |m| m.state(deploy.stage.deploy_groups) == "Alert" }
    end

    def validate_deploy(deploy, job_execution)
      # not logging anything for common cases to reduce spam
      return true unless deploy.succeeded?
      return true unless monitors = deploy.datadog_monitors_for_validation.presence

      interval = 1.minute
      iterations = monitors.map { |m| m.check_duration.to_i }.max / interval + 1

      iterations.times do |i|
        Samson::Parallelizer.map(monitors, &:reload_from_api)
        alerting = monitors.select { |m| m.state(deploy.stage.deploy_groups) == "Alert" }

        # all monitors good
        if alerting.none?
          remaining = iterations - i - 1
          job_execution.output.puts "No datadog monitors alerting#{" #{remaining} min remaining" if remaining > 0}"

          monitors.reject! { |m| m.check_duration.to_i <= (i * interval) } # stop checking the done ones
          return true if monitors.none?

          sleep interval
          next
        end

        # some monitors alerting
        job_execution.output.puts "Alert on datadog monitors:\n#{alerting.map { |m| "#{m.name} #{m.url}" }.join("\n")}"

        alerting.each do |monitor|
          case monitor.failure_behavior
          when "redeploy_previous"
            deploy.redeploy_previous_when_failed = true
            job_execution.output.puts "Trying to redeploy previous succeeded deploy"
          when "fail_deploy" then nil # noop
          else raise ArgumentError, "unsupported failure behavior #{monitor}"
          end
        end
        break
      end

      false # mark deploy as failed
    end
  end
end

Samson::Hooks.view :stage_form, "samson_datadog"
Samson::Hooks.view :stage_show, "samson_datadog"

Samson::Hooks.callback :stage_permitted_params do
  [
    :datadog_tags,
    {
      datadog_monitor_queries_attributes: [
        :query, :failure_behavior, :match_target, :match_source, :check_duration, :_destroy, :id
      ]
    }
  ]
end

Samson::Hooks.callback :before_deploy do |deploy, _|
  SamsonDatadog.send_notification(deploy, additional_tags: ['started'], now: true)
  SamsonDatadog.store_validation_monitors(deploy)
end

Samson::Hooks.callback :validate_deploy do |deploy, job_execution|
  SamsonDatadog.validate_deploy(deploy, job_execution)
end

Samson::Hooks.callback :after_deploy do |deploy, _job_execution|
  SamsonDatadog.send_notification(deploy, additional_tags: ['finished'])
end
