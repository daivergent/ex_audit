defmodule ExAudit.Queryable do
  require Logger

  import Ecto.Query, only: [from: 2, where: 3]

  defp version_schema() do
    Application.get_env(:ex_audit, :version_schema)
  end

  @compile {:inline, version_schema: 0}

  def update_all(module, queryable, updates, opts) do
    Ecto.Repo.Queryable.update_all(module, queryable, updates, opts)
  end

  def delete_all(module, queryable, opts) do
    Ecto.Repo.Queryable.delete_all(module, queryable, opts)
  end

  def history(module, struct, opts) do
    query =
      from(
        v in version_schema(),
        order_by: [desc: :recorded_at]
      )

    # TODO what do when we get a query
    schema = Map.get(struct, :__struct__)
    entity_id = get_entity_id(schema, struct)

    query =
      case {is_struct(struct), is_binary(entity_id)} do
        {true, true} ->
          from(
            v in query,
            where: v.entity_id == ^entity_id,
            where: v.entity_schema == ^schema
          )

        {true, false} ->
          from(
            v in query,
            where: v.entity_schema == ^schema
          )

        _ ->
          query
      end

    versions = Ecto.Repo.Queryable.all(module, query, Ecto.Repo.Supervisor.tuplet(module, opts))

    if Keyword.get(opts, :render_struct, false) do
      {versions, oldest_struct} =
        versions
        |> Enum.map_reduce(struct, fn version, new_struct ->
          old_struct = _revert(version, new_struct)

          version =
            version
            |> Map.put(:original, empty_map_to_nil(new_struct))
            |> Map.put(:first, false)

          {version, old_struct}
        end)

      {versions, oldest_id} =
        versions
        |> Enum.map_reduce(nil, fn version, id ->
          {%{version | id: id}, version.id}
        end)

      versions ++
        [
          struct(version_schema(), %{
            id: oldest_id
          })
          |> Map.put(:original, empty_map_to_nil(oldest_struct))
        ]
    else
      versions
    end
  end

  def history_query(%{id: id, __struct__: struct}) do
    from(
      v in version_schema(),
      where: v.entity_id == ^id,
      where: v.entity_schema == ^struct,
      order_by: [desc: :recorded_at]
    )
  end

  @drop_fields [:__meta__, :__struct__]

  def revert(module, version, opts) do
    import Ecto.Query

    # get the history of the entity after this version

    query =
      from(
        v in version_schema(),
        where: v.entity_id == ^version.entity_id,
        where: v.entity_schema == ^version.entity_schema,
        where: v.recorded_at >= ^version.recorded_at,
        order_by: [desc: :recorded_at]
      )

    versions = module.all(query)

    # get the referenced struct as it exists now

    struct = module.one(from(s in version.entity_schema, where: s.id == ^version.entity_id))

    result = Enum.reduce(versions, struct, &_revert/2)

    result = empty_map_to_nil(result)

    schema = version.entity_schema

    drop_from_params = @drop_fields ++ schema.__schema__(:associations)

    {action, changeset} =
      case {struct, result} do
        {nil, %{}} ->
          {:insert, schema.changeset(struct(schema, %{}), Map.drop(result, drop_from_params))}

        {%{}, nil} ->
          {:delete, struct}

        {nil, nil} ->
          {nil, nil}

        _ ->
          struct =
            case Keyword.get(opts, :preload) do
              nil -> struct
              [] -> struct
              preloads when is_list(preloads) -> module.preload(struct, preloads)
            end

          {:update, schema.changeset(struct, Map.drop(result, drop_from_params))}
      end

    opts =
      Keyword.update(opts, :ex_audit_custom, [rollback: true], fn custom ->
        [{:rollback, true} | custom]
      end)

    if action do
      res = apply(module, action, [changeset, opts])

      case action do
        :delete -> {:ok, nil}
        _ -> res
      end
    else
      Logger.warning([
        "Can't revert ",
        inspect(version),
        " because the entity would still be deleted"
      ])

      {:ok, nil}
    end
  end

  defp empty_map_to_nil(map) do
    if map |> Map.keys() |> length() == 0 do
      nil
    else
      map
    end
  end

  defp _revert(version, struct) do
    apply_change(reverse_action(version.action), ExAudit.Diff.reverse(version.patch), struct)
  end

  defp apply_change(:updated, patch, to) do
    ExAudit.Patch.patch(to, patch)
  end

  defp apply_change(:deleted, _patch, _to) do
    %{}
  end

  defp apply_change(:created, patch, _to) do
    ExAudit.Patch.patch(%{}, patch)
  end

  defp reverse_action(:updated), do: :updated
  defp reverse_action(:created), do: :deleted
  defp reverse_action(:deleted), do: :created

  defp get_entity_id(schema, struct) do
    primary_key =
      case schema.__schema__(:primary_key) do
        primary_key_list when is_list(primary_key_list) ->
          List.first(primary_key_list)

        _ ->
          nil
      end

    entity_id = Map.get(struct, primary_key)

    if is_integer(entity_id) do
      Integer.to_string(entity_id)
    else
      entity_id
    end
  end
end
