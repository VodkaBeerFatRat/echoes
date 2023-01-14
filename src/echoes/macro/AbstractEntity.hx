package echoes.macro;

import haxe.macro.ComplexTypeTools;
import haxe.macro.Expr;
import haxe.macro.Printer;
import haxe.macro.Type;
import haxe.macro.TypeTools;

using echoes.macro.ComponentStorageBuilder;
using echoes.macro.EntityTools;
using echoes.macro.MacroTools;
using haxe.EnumTools;
using haxe.macro.Context;
using haxe.macro.ExprTools;
using Lambda;

/**
 * An alternate way to define entities, allowing you to access components as
 * if they were instance variables. Sample usage:
 * 
 * ```haxe
 * @:build(echoes.Entity.build())
 * abstract Fighter(Entity) {
 *     //Each variable represents a different component.
 *     public var damage:Damage = 1;
 *     public var health:Health = 10;
 *     public var hitbox:Hitbox = Hitbox.square(1);
 *     public var sprite:Sprite;
 *     
 *     //Variables may also be initialized in the constructor, as normal. A
 *     //default constructor will be created if you leave it out.
 *     public inline function new(sprite:Sprite) {
 *         this = new Entity();
 *         
 *         //Due to how abstracts work, you can't set `this.sprite = sprite`.
 *         //Instead, either rename the parameter or use a workaround:
 *         this.add(sprite);
 *         set_sprite(sprite);
 *         var self:Fighter = cast this;
 *         self.sprite = sprite;
 *     }
 *     
 *     //Other functions work normally.
 *     public inline function getDamage(target:Hitbox):Damage {
 *         if(target.overlapping(hitbox)) {
 *             return damage;
 *         } else {
 *             return 0;
 *         }
 *     }
 * }
 * 
 * class Main {
 *     public static function main():Void {
 *         var knight:Fighter = new Fighter(SpriteCache.get("knight.png"));
 *         
 *         //The variables now act as shortcuts for `add()` and `get()`.
 *         trace(knight.health); //10
 *         trace(knight.get(Health)); //10
 *         
 *         //Because the variables all have type hints, you don't need to
 *         //specify which type you mean.
 *         knight.health = 9;
 *         knight.damage = 3;
 *         trace(knight.get(Health)); //9
 *         trace(knight.get(Damage)); //3
 *         
 *         //If using `add()`, the normal rules apply.
 *         knight.add((8:Health));
 *         trace(knight.health); //8
 *         
 *         //The macro also defines the function `Fighter.convert()`, which
 *         //turns an already-existing entity into a `Fighter` by adding the
 *         //necessary components.
 *         var greenKnight:Entity = new Entity();
 *         greenKnight.add(Color.GREEN);
 *         greenKnight.health = 20;
 *         
 *         var greenFighter:Fighter = Fighter.convert(greenKnight);
 *         
 *         //`convert()` doesn't overwrite already-defined components.
 *         trace(greenFighter.health); //20
 *         
 *         //`convert()` uses the default value for each missing component.
 *         trace(greenFighter.damage); //1
 *         trace("0x" + StringTools.hex(greenFighter.get(Color), 6)); //0x00FF00
 *         
 *         //Since `sprite` has no default value, `convert()` won't add it.
 *         trace(greenFighter.sprite); //null
 *     }
 * }
 * ```
 */
class AbstractEntity {
	public static function build():Array<Field> {
		var fields:Array<Field> = Context.getBuildFields();
		
		//Information gathering
		//=====================
		
		//Get information about the `abstract` being built.
		var type:AbstractType = switch(Context.getLocalType()) {
			case TInst(_.get().kind => KAbstractImpl(_.get() => type), _):
				type;
			default:
				Context.fatalError("Entity.build() only works on abstract types.", Context.currentPos());
		};
		
		if(type.params != null && type.params.length > 0) {
			Context.fatalError('${ type.name } may not have any parameters.', Context.currentPos());
		}
		
		//Get information about parent types, and allow converting to each.
		var parentType:Type = type.type;
		var parentMakeExpr:Null<Expr> = null;
		var isEntity:Bool = false;
		for(i in 0...100) {
			switch(parentType) {
				case TInst(_.get().kind => KAbstractImpl(_.get() => parentAbstract), _),
					TAbstract(_.get() => parentAbstract, _):
					var name:String = "to" + parentAbstract.name;
					var complexType:ComplexType = parentType.toComplexType();
					fields.pushFields(macro class ToParent {
						@:to private inline function $name():$complexType {
							return cast this;
						}
					});
					
					if(parentAbstract.name == "Entity" && parentAbstract.pack.length == 1 && parentAbstract.pack[0] == "echoes") {
						isEntity = true;
						break;
					} else {
						parentType = parentAbstract.type;
					}
				default:
					break;
			}
		}
		
		if(!isEntity) {
			Context.fatalError('${ type.name } must wrap echoes.Entity.', Context.currentPos());
		}
		
		//Modifications
		//=============
		
		//Forward all parent fields.
		if(!type.meta.has(":forward")) {
			type.meta.add(":forward", [], type.pos);
		}
		
		//Process the variables.
		var initializeVariables:Array<{ name:String, expr:Expr }> = [];
		for(field in fields) {
			//Parse the field kind.
			var componentType:Null<ComplexType>;
			var expr:Null<Expr>;
			switch(field.kind) {
				//Skip static variables, but not static properties.
				case FVar(_, _) if(field.access != null && field.access.contains(AStatic)):
					continue;
				case FVar(t, e), FProp(_, _, t, e):
					componentType = t;
					expr = e;
				default:
					continue;
			}
			
			//Infer the component type, if not explicitly specified.
			if(componentType == null) {
				if(expr != null) {
					try {
						componentType = expr.parseComponentType().toComplexType();
					} catch(e:haxe.Exception) {
					}
				}
				
				if(componentType == null) {
					Context.fatalError('${ field.name } requires a type.', field.pos);
					continue;
				}
			}
			
			//Record the initial value.
			if(expr != null) {
				initializeVariables.push({
					name: switch(componentType) {
						case TPath({ name: name, sub: null }):
							name;
						case TPath({ sub: sub }):
							sub;
						default:
							new Printer().printComplexType(componentType);
					},
					expr: macro entity.addIfMissing(($expr:$componentType))
				});
			}
			
			//Check for reserved types.
			switch(componentType) {
				case macro:Entity, macro:echoes.Entity:
					Context.fatalError("Entity is reserved. Consider using a typedef, abstract, or Int", field.pos);
				case macro:Float, macro:StdTypes.Float:
					Context.fatalError("Float is reserved for lengths of time. Consider using a typedef or abstract", field.pos);
				default:
			}
			
			//Convert the field to a property, and remove the expression.
			field.kind = FProp("get", "set", componentType, null);
			
			var getter:String = "get_" + field.name;
			var setter:String = "set_" + field.name;
			
			fields.pushFields(macro class Accessors {
				private inline function $getter():$componentType {
					return this.get((_:$componentType));
				}
				
				private inline function $setter(value:$componentType):$componentType {
					this.add(value);
					return value;
				}
			});
		}
		
		//Add the `convert()` function.
		var complexType:ComplexType = TPath({ pack: [], name: type.name });
		fields.pushFields(macro class Convert {
			public static function convert(entity:echoes.Entity):$complexType $b{
				initializeVariables.map(v -> v.expr)
					.concat([macro return cast entity])
			}
		});
		if(initializeVariables.length > 0) {
			fields[fields.length - 1].doc = 'Converts an entity to `${ type.name }` by '
				+ "adding any of the following that don't already exist: `"
				+ initializeVariables.map(v -> v.name).join("`, `")
				+ "`.";
		}
		
		//Add a default constructor, if needed.
		var constructor:Field = fields.find(field -> field.name == "new" || field.name == "_new");
		if(constructor == null) {
			var parentTypePath:TypePath = switch(type.type.toComplexType()) {
				case TPath(p):
					p;
				case x:
					//This shouldn't be possible after the `isEntity` test, but
					//it's easy enough 
					Context.error("Can't call new " + new Printer().printComplexType(x) + "().", Context.currentPos());
			};
			
			constructor = (macro class DefaultConstructor {
				public inline function new() {
					//Assume the parent type takes no arguments. If it does, the
					//user will have to define their own constructor.
					this = new $parentTypePath();
				}
			}).fields[0];
			
			fields.push(constructor);
		}
		
		//Make sure the constructor calls `convert()`.
		switch(constructor.kind) {
			case FFun(func):
				var block:Array<Expr> = switch(func.expr.expr) {
					case EBlock(exprs):
						exprs;
					default:
						[func.expr];
				};
				
				for(i => expr in block) {
					if(expr.expr.match(EBinop(OpAssign, { expr: EConst(CIdent("this")) }, _))) {
						block.insert(i + 1, macro convert(this));
						break;
					}
				}
			default:
		}
		
		return fields;
	}
}
