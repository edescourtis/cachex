defmodule Cachex.MemoizeTest do
  use CachexCase

  test "simple memoization" do
    Cachex.start(:memoize_test_cache)
    defmodule M do
      use Cachex.Memoize
      defmemo ref(), cache: :memoize_test_cache do
        make_ref()
      end
    end

    a = M.ref()
    b = M.ref()

    assert(a === b)
  end
end