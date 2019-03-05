defmodule Cachex.Memoize do
  @moduledoc """
  ## Cachex.Memoize

  Cachex.Memoize provides straightforward memoization macros using Cachex as a backend.

  ## How to memoize

  If you want to cache a function, `use Cachex.Memoize` on the module and change `def` to `defmemo` and specify a cache.
  IMPORTANT! If your cache is not started the function will run directly without Cachex.

  for example:

  ```elixir
  defmodule MyMod do
    def f(x) do
      Process.sleep(1000)
      x + 1
    end
  end
  ```

  this code changes to:

  ```elixir
  Cachex.start(:mycache) # Normally you would `start_link` Cachex in a supervisor.

  defmodule MyMod do
    use Cachex.Memoize
    defmemo f(x), cache: :mycache do
      Process.sleep(1000)
      x + 1
    end
  end
  ```

  If a function defined by `defmemo` raises an error, the result is not cached and one of waiting processes will call the function.

  ## Exclusive

  A caching function that is defined by `defmemo` is never called in parallel.

  ```elixir
  defmodule Calc do
  use Memoize
  defmemo calc() do
    Process.sleep(1000)
    IO.puts "called!"
  end
  end

  # call `Calc.calc/0` in parallel using many processes.
  for _ <- 1..10000 do
  Process.spawn(fn -> Calc.calc() end, [])
  end

  # but, actually `Calc.calc/0` is called only once.
  ```
  """

  defmacro __using__(_) do
    quote do
      import Cachex.Memoize, only: [defmemo: 1, defmemo: 2, defmemo: 3, defmemop: 1, defmemop: 2, defmemop: 3]
      @memoize_memodefs []
      @memoize_origdefined %{}
      @before_compile Cachex.Memoize
    end
  end

  defmacro defmemo(call, expr_or_opts \\ nil) do
    {opts, expr} = resolve_expr_or_opts(expr_or_opts)
    define(:def, call, opts, expr)
  end

  defmacro defmemop(call, expr_or_opts \\ nil) do
    {opts, expr} = resolve_expr_or_opts(expr_or_opts)
    define(:defp, call, opts, expr)
  end

  defmacro defmemo(call, opts, expr) do
    define(:def, call, opts, expr)
  end

  defmacro defmemop(call, opts, expr) do
    define(:defp, call, opts, expr)
  end

  defp resolve_expr_or_opts(expr_or_opts) do
    cond do
      expr_or_opts == nil ->
        {[], nil}

      # expr_or_opts is expr
      Keyword.has_key?(expr_or_opts, :do) ->
        {[], expr_or_opts}

      # expr_or_opts is opts
      true ->
        {expr_or_opts, nil}
    end
  end

  defp define(method, call, _opts, nil) do
    # declare function
    quote do
      case unquote(method) do
        :def -> def unquote(call)
        :defp -> defp unquote(call)
      end
    end
  end

  defp define(method, call, opts, expr) do
    register_memodef =
      case call do
        {:when, meta, [{origname, exprmeta, args}, right]} ->
          quote bind_quoted: [
                  expr: Macro.escape(expr, unquote: true),
                  origname: Macro.escape(origname, unquote: true),
                  exprmeta: Macro.escape(exprmeta, unquote: true),
                  args: Macro.escape(args, unquote: true),
                  meta: Macro.escape(meta, unquote: true),
                  right: Macro.escape(right, unquote: true)
                ] do
            require Cachex.Memoize

            fun = {:when, meta, [{Cachex.Memoize.__memoname__(origname), exprmeta, args}, right]}
            @memoize_memodefs [{fun, expr} | @memoize_memodefs]
          end

        {origname, exprmeta, args} ->
          quote bind_quoted: [
                  expr: Macro.escape(expr, unquote: true),
                  origname: Macro.escape(origname, unquote: true),
                  exprmeta: Macro.escape(exprmeta, unquote: true),
                  args: Macro.escape(args, unquote: true)
                ] do
            require Cachex.Memoize

            fun = {Cachex.Memoize.__memoname__(origname), exprmeta, args}
            @memoize_memodefs [{fun, expr} | @memoize_memodefs]
          end
      end

    fun =
      case call do
        {:when, _, [fun, _]} -> fun
        fun -> fun
      end

    deffun =
      quote bind_quoted: [
              fun: Macro.escape(fun, unquote: true),
              method: Macro.escape(method, unquote: true),
              opts: Macro.escape(opts, unquote: true)
            ] do
        {origname, from, to} = Cachex.Memoize.__expand_default_args__(fun)
        memoname = Cachex.Memoize.__memoname__(origname)

        for n <- from..to do
          args = Cachex.Memoize.__make_args__(n)

          unless Map.has_key?(@memoize_origdefined, {origname, n}) do
            @memoize_origdefined Map.put(@memoize_origdefined, {origname, n}, true)
            location = __ENV__ |> Macro.Env.location()
            file = location |> Keyword.get(:file)
            line = location |> Keyword.get(:line)
            "Elixir." <> module = __ENV__ |> Map.get(:module) |> Atom.to_string()
            unless opts |> Keyword.has_key?(:cache) do
              raise "#{file}:#{line} #{module}.#{origname} missing mandatory parameter 'cache' (see Cachex.Memoize for documentation)"
            end

            unquote(method) (unquote(origname)(unquote_splicing(args))) do
              key = {__MODULE__, unquote(origname), [unquote_splicing(args)]}
              memo_opts = unquote(opts)
              cache = memo_opts |> Keyword.get(:cache)
              case Cachex.transaction(cache, [key], fn cache ->
                case Cachex.get(cache, key) do
                  {:ok, nil} ->
                    result = try do
                      {:success, unquote(memoname)(unquote_splicing(args))}
                    catch
                      :error, %RuntimeError{message: payload} ->
                        {:raise, payload}
                      :error, payload ->
                        {:error, payload}
                      :throw, payload ->
                        {:throw, payload}
                      :exit, payload ->
                        {:exit, payload}
                    end
                    put_opts = if Keyword.has_key?(memo_opts, :ttl) do
                      [ttl: memo_opts |> Keyword.get(:ttl)]
                    else
                      []
                    end
                    {:ok, true} = Cachex.put(cache, key, result, put_opts)
                    result
                  {:ok, result} ->
                    result
                  {:error, :no_cache} ->
                    unquote(memoname)(unquote_splicing(args))
                end
              end) do
                {:ok, result} ->
                  case result do
                    {:success, result} -> result
                    {:raise, payload}  -> Kernel.raise(payload)
                    {:error, payload}  -> :erlang.error(payload)
                    {:throw, payload}  -> Kernel.throw(payload)
                    {:exit, payload}   -> Kernel.exit(payload)
                  end
                {:error, :no_cache} ->
                  unquote(memoname)(unquote_splicing(args))
              end
            end
          end
        end
      end

    [register_memodef, deffun]
  end


  # {:foo, 1, 3} == __expand_default_args__(quote(do: foo(x, y \\ 10, z \\ 20)))
  def __expand_default_args__(fun) do
    {name, args} = Macro.decompose_call(fun)

    is_default_arg = fn
      {:\\, _, _} -> true
      _ -> false
    end

    min_args = Enum.reject(args, is_default_arg)
    {name, length(min_args), length(args)}
  end

  # [] == __make_args__(0)
  # [{:t1, [], Elixir}, {:t2, [], Elixir}] == __make_args__(2)
  def __make_args__(0) do
    []
  end

  def __make_args__(n) do
    for v <- 1..n do
      {:"t#{v}", [], Elixir}
    end
  end

  def __memoname__(origname), do: :"__#{origname}_cachex_memoize"

  defmacro __before_compile__(_) do
    quote do
      @memoize_memodefs
      |> Enum.reverse()
      |> Enum.map(fn {memocall, expr} ->
        Code.eval_quoted({:defp, [], [memocall, expr]}, [], __ENV__)
      end)
    end
  end


end
