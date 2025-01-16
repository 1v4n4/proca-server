defmodule ProcaWeb.Telemetry do
  @moduledoc false

  use Supervisor
  require Logger

  import Telemetry.Metrics

  @campaign_tags [:campaign_id, :campaign_name]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    children =
      if enable_telemetry?() do
        [
          {:telemetry_poller,
           measurements: periodic_measurements(),
           period: :timer.seconds(60),
           init_delay: :timer.seconds(30)},
          {TelemetryMetricsPrometheus, [metrics: metrics()]}
        ]
      else
        []
      end

    :telemetry.attach(
      "query-time-handler",
      [:proca, :repo, :query],
      &ProcaWeb.Telemetry.handle_event/4,
      []
    )

    Supervisor.init(children, strategy: :one_for_one)
  end

  def handle_event([:proca, :repo, :query], measurements, metadata, _config) do
    query_duration = System.convert_time_unit(measurements.query_time, :native, :millisecond)

    if query_duration > 10_000 do
      Logger.warning("""
      Slow query detected (#{query_duration}ms)
      Query: #{metadata.query}
      """)
    end
  end

  def count_sendable_messages do
    import Ecto.Query

    active_campaigns =
      from(c in Proca.Campaign,
        join: mtt in Proca.MTT,
        on: mtt.campaign_id == c.id,
        where: mtt.start_at <= from_now(0, "day") and mtt.end_at >= from_now(0, "day"),
        preload: [:mtt],
        order_by: fragment("RANDOM()")
      )
      |> Proca.Repo.all()

    Enum.each(active_campaigns, fn campaign ->
      unsent_messages =
        Proca.Action.Message.select_by_campaign(campaign.id)
        |> Proca.Repo.all()
        |> length()

      :telemetry.execute([:proca, :mtt], %{sendable_messages: unsent_messages}, %{
        campaign_id: campaign.id,
        campaign_name: campaign.name
      })
    end)
  end

  defp metrics do
    [
      # MTT Metrics
      counter("proca.mailjet.events.count", tags: [:reason]),
      counter("proca.mailjet.bounces.count", tags: [:reason]),
      last_value("proca.mtt.campaigns_running"),
      last_value("proca.mtt.sendable_messages", tags: @campaign_tags),
      last_value("proca.mtt.sendable_targets", tags: @campaign_tags),
      last_value("proca.mtt.current_cycle", tags: @campaign_tags),
      last_value("proca.mtt.all_cycles", tags: @campaign_tags),
      sum("proca.mtt.messages_sent", tags: @campaign_tags)
      # Database Metrics
      last_value("proca.repo.query.total_time", unit: {:native, :millisecond}),
      last_value("proca.repo.query.decode_time", unit: {:native, :millisecond}),
      last_value("proca.repo.query.query_time", unit: {:native, :millisecond}),
      last_value("proca.repo.query.queue_time", unit: {:native, :millisecond}),
      last_value("proca.repo.query.idle_time", unit: {:native, :millisecond})
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      {ProcaWeb.Telemetry, :count_sendable_messages, []}
    ]
  end

  defp enable_telemetry? do
    Application.get_env(:proca, __MODULE__, %{enable: true})[:enable]
  end
end
