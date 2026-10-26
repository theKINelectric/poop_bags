defmodule PoopBags.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias PoopBags.ProjectConfig

  @tag :tmp_dir
  test "defaults with no config file", ctx do
    assert {:ok, config} = ProjectConfig.load(ctx.tmp_dir)
    assert config.exclude == []
    assert config.coverage_report == nil
    assert config.threshold == 20.0
    assert config.source == "defaults"
    assert config.digest == "none"
  end

  @tag :tmp_dir
  test "reads .poopbags.json and resolves relative paths", ctx do
    File.write!(Path.join(ctx.tmp_dir, ".poopbags.json"), ~s({
      "exclude": ["experiments/**"],
      "coverage_report": "cover/lcov.info",
      "threshold": 30,
      "languages": ["zig"]
    }))

    File.mkdir_p!(Path.join(ctx.tmp_dir, "cover"))
    File.write!(Path.join(ctx.tmp_dir, "cover/lcov.info"), "")

    assert {:ok, config} = ProjectConfig.load(ctx.tmp_dir)
    assert config.exclude == ["experiments/**"]
    assert config.coverage_report == Path.join(ctx.tmp_dir, "cover/lcov.info")
    assert config.threshold == 30.0
    assert config.languages == [:zig]
    assert config.source == ".poopbags.json"
    assert byte_size(config.digest) == 64
    assert ProjectConfig.excluded?(config, "experiments/a/hb.zig")
    refute ProjectConfig.excluded?(config, "src/a.zig")
    assert ProjectConfig.language_allowed?(config, :zig)
    refute ProjectConfig.language_allowed?(config, :elixir)
  end

  @tag :tmp_dir
  test "overrides beat the file, file beats defaults", ctx do
    File.write!(Path.join(ctx.tmp_dir, ".poopbags.json"), ~s({"threshold": 30}))

    assert {:ok, config} =
             ProjectConfig.load(ctx.tmp_dir, %{"threshold" => 50, "exclude" => ["x/**"]})

    assert config.threshold == 50.0
    assert config.exclude == ["x/**"]
  end

  @tag :tmp_dir
  test "a configured-but-missing coverage report stays configured", ctx do
    # Silently degrading to assumed-only would hide a broken CI setup: the
    # path survives so the engine treats it as a broken report (CI fails,
    # web warns) — same strictness as an unparseable one.
    File.write!(Path.join(ctx.tmp_dir, ".poopbags.json"), ~s({"coverage_report": "gone.info"}))

    assert {:ok, config} = ProjectConfig.load(ctx.tmp_dir)
    assert config.coverage_report == Path.join(ctx.tmp_dir, "gone.info")
  end

  @tag :tmp_dir
  test "invalid JSON is a load error, never an evaluation", ctx do
    File.write!(Path.join(ctx.tmp_dir, ".poopbags.json"), "{not json at all")
    assert {:error, message} = ProjectConfig.load(ctx.tmp_dir)
    assert message =~ "not valid JSON"
  end

  @tag :tmp_dir
  test "snapshot is JSON-ready and carries the digest", ctx do
    File.write!(Path.join(ctx.tmp_dir, ".poopbags.json"), ~s({"threshold": 5}))
    {:ok, config} = ProjectConfig.load(ctx.tmp_dir)
    snap = ProjectConfig.snapshot(config)

    assert snap["threshold"] == 5.0
    assert snap["digest"] == config.digest
    assert snap["source"] == ".poopbags.json"
    Jason.encode!(snap)
  end
end
