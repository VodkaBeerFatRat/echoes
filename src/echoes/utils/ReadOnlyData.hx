package echoes.utils;

@:forward(first, iterator, isEmpty, last, length)
@:forward.new
abstract ReadOnlyList<T>(List<T>) from List<T> to Iterable<T> {
	public inline function has(item:T):Bool return Lambda.has(this, item);
}

@:forward(contains, iterator, length)
@:forward.new
abstract ReadOnlyArray<T>(Array<T>) from Array<T> to Iterable<T> {
	@:arrayAccess private inline function get(index:Int):T {
		return this[index];
	}
}
