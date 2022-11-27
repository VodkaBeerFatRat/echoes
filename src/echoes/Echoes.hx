package echoes;

import echoes.ComponentStorage;
import echoes.Entity;
import echoes.utils.ReadOnlyData;
import echoes.View;

#if macro
import haxe.macro.Expr;
import haxe.macro.Printer;

using echoes.macro.MacroTools;
using echoes.macro.ViewBuilder;
using haxe.macro.Context;
#end

class Echoes {
	#if ((haxe_ver < 4.2) && macro)
	private static function __init__():Void {
		Context.error("Error: Echoes requires at least Haxe 4.2.", Context.currentPos());
	}
	#end
	
	@:allow(echoes.Entity) @:allow(echoes.ComponentStorage)
	private static var componentStorage:Array<DynamicComponentStorage> = [];
	
	@:allow(echoes.Entity)
	private static var _activeEntities:List<Entity> = new List();
	public static var activeEntities(get, never):ReadOnlyList<Entity>;
	private static inline function get_activeEntities():ReadOnlyList<Entity> return _activeEntities;
	
	@:allow(echoes.ViewBase)
	private static var _activeViews:Array<ViewBase> = [];
	public static var activeViews(get, never):ReadOnlyArray<ViewBase>;
	private static inline function get_activeViews():ReadOnlyArray<ViewBase> return _activeViews;
	
	private static var _activeSystems:Array<System> = [];
	public static var activeSystems(get, never):ReadOnlyArray<System>;
	private static inline function get_activeSystems():ReadOnlyArray<System> return _activeSystems;
	
	#if echoes_profiling
	private static var lastUpdateLength:Int = 0;
	#end
	
	private static var lastUpdate:Float = 0;
	private static var initialized:Bool = false;
	
	/**
	 * @param fps The number of updates to perform each second. If this is zero,
	 * you will need to call `Echoes.update()` yourself.
	 */
	public static function init(?fps:Float = 60):Void {
		if(!initialized) {
			initialized = true;
			lastUpdate = haxe.Timer.stamp();
			
			if(fps > 0) {
				new haxe.Timer(Std.int(1000 / fps)).run = update;
			}
		}
	}
	
	/**
	 * Returns the app statistics:
	 * 
	 * ```text
	 * ( systems count ) { views count } [ entities count | entity cache size ]
	 * ```
	 * 
	 * If `echoes_profiling` is set, additionally returns:
	 * 
	 * ```text
	 *  : update time ms
	 * ( system name ) : update time ms
	 * { view name } [ entities in view ]
	 * ```
	 */
	public static function info():String {
		var ret = '# ( ${activeSystems.length} ) { ${activeViews.length} } [ ${activeEntities.length} | ${Entity.idPool.length} ]'; // TODO version or something
		
		#if echoes_profiling
		ret += ' : $lastUpdateLength ms'; // total
		for(system in activeSystems) {
			ret += '\n${ system.info('    ', 1) }';
		}
		for(view in activeViews) {
			ret += '\n    {$view} [${ view.entities.length }]';
		}
		#end
		
		return ret;
	}
	
	/**
	 * Updates all active systems.
	 */
	public static function update():Void {
		var startTime:Float = haxe.Timer.stamp();
		var dt:Float = startTime - lastUpdate;
		lastUpdate = startTime;
		
		for(system in activeSystems) {
			system.__update__(dt);
		}
		
		#if echoes_profiling
		lastUpdateLength = Std.int((haxe.Timer.stamp() - startTime) * 1000);
		#end
	}
	
	/**
	 * Deactivates all views and systems and destroys all entities.
	 */
	public static function reset():Void {
		for(entity in activeEntities) {
			entity.destroy();
		}
		
		//Iterate backwards when removing items from arrays.
		var i:Int = activeSystems.length;
		while(--i >= 0) {
			removeSystem(activeSystems[i]);
		}
		i = activeViews.length;
		while(--i >= 0) {
			activeViews[i].reset();
		}
		for(storage in componentStorage) {
			storage.clear();
		}
		
		Entity.idPool.resize(0);
		Entity.statuses.resize(0);
		
		Entity.nextId = 0;
	}
	
	//System management
	//=================
	
	public static function addSystem(system:System):Void {
		if(!hasSystem(system)) {
			_activeSystems.push(system);
			system.__activate__();
		}
	}
	
	public static function removeSystem(system:System):Void {
		if(_activeSystems.remove(system)) {
			system.__deactivate__();
		}
	}
	
	public static inline function hasSystem(system:System):Bool {
		return activeSystems.contains(system);
	}
	
	//Singleton management
	//====================
	
	/**
	 * Returns the expected `View` or `ComponentStorage` instance. May also work
	 * for other `@:genericBuild` types, but those aren't officially supported.
	 * 
	 * To use this function, you must explicitly specify the expected type:
	 * 
	 * ```haxe
	 * var stringView:View<String> = Echoes.getSingleton();
	 * var colorShapeView = (Echoes.getSingleton():View<Color, Shape>);
	 * 
	 * var stringStorage:ComponentStorage<String> = Echoes.getSingleton();
	 * var colorStorage:ComponentStorage<Color> = Echoes.getSingleton();
	 * var shapeStorage = (Echoes.getSingleton():ComponentStorage<Shape>);
	 * ```
	 * @param activateView Whether to activate the `View` before returning it.
	 * Has no effect on `ComponentStorage` or any other type.
	 * @see `System.makeLinkedView()`
	 */
	//Tip: macros can call this function too!
	public static #if !macro macro #end function getSingleton(?activateView:Bool = true):Expr {
		//There's no need to invoke the builder; Haxe will automatically do so
		//at least once.
		switch(Context.getExpectedType().followMono().toComplexType()) {
			case TPath({ pack: [], name: className, params: [] }):
				if(className.isView() && activateView) {
					return macro {
						$i{ className }.instance.activate();
						$i{ className }.instance;
					};
				} else {
					return macro $i{ className }.instance;
				}
			case TPath(p):
				Context.error(new Printer().printComplexType(TPath(p)) + " is not a supported type.", Context.currentPos());
			default:
				Context.error("getSingleton() called without an expected type", Context.currentPos());
		}
		
		return macro null;
	}
}
