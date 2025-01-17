package echoes.macro;

#if macro

import haxe.macro.Expr;
import haxe.macro.Printer;
import haxe.macro.Type;

using echoes.macro.MacroTools;
using haxe.macro.Context;
using haxe.macro.ComplexTypeTools;

class ComponentStorageBuilder {
	private static var storageCache:Map<String, TypeDefinition> = new Map();
	
	private static var registered:Bool = false;
	
	public static function getComponentStorage(componentComplexType:ComplexType):ComplexType {
		var componentTypeName:String = componentComplexType.followName();
		switch(componentTypeName) {
			case "echoes.Entity":
				Context.error("Entity is not an allowed component type. Try using a typedef, an abstract, or Int instead.", Context.currentPos());
			case "StdTypes.Float":
				Context.error("Float is not an allowed component type. Try using a typedef or an abstract instead.", Context.currentPos());
			default:
		}
		
		var storageTypeName:String = "ComponentStorage_" + componentComplexType.toIdentifier();
		var storageTypePath:TypePath = { pack: [], name: storageTypeName };
		var storageType:ComplexType = TPath(storageTypePath);
		
		if(storageCache.exists(storageTypeName)) {
			return storageType;
		}
		
		var def:TypeDefinition = macro class $storageTypeName extends echoes.ComponentStorage<$componentComplexType> {
			public static final instance:$storageType = new $storageTypePath();
			
			private function new() {
				super($v{ componentTypeName });
			}
		};
		
		storageCache.set(storageTypeName, def);
		if(!registered) {
			registered = true;
			Context.onTypeNotFound(storageCache.get);
		}
		
		Report.componentNames.push(componentTypeName);
		Report.gen();
		
		return storageType;
	}
}

#end
