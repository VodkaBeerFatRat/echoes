package ecs.core.macro;


import haxe.Log;
#if macro
import haxe.macro.MacroStringTools;
import tink.macro.Types;
import haxe.macro.ExprTools;
import ecs.core.macro.MacroTools.*;
import ecs.core.macro.ViewBuilder.*;
import ecs.core.macro.ComponentBuilder.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Printer;
import haxe.macro.Type.ClassField;

using haxe.macro.ComplexTypeTools;
using haxe.macro.TypeTools;
using haxe.macro.Context;
using ecs.core.macro.MacroTools;
using tink.MacroApi;
using StringTools;
using Lambda;

typedef ViewRec = { name:String, cls:ComplexType, components:Array<{ cls:ComplexType }> };
typedef UpdateRec = { name: String,  rawargs: Array<FunctionArg>, meta:haxe.ds.Map<String,Array<Array<Expr>>>, args: Array<Expr>, view: ViewRec, viewargs: Array<FunctionArg>, type: MetaFuncType };


enum ParallelType {
    PUnknown;
    PFull;
    PHalf;
    PDouble;
    PCount(n : Int);
}

class SystemBuilder {


    static var SKIP_META = [ 'skip' ];

    static var PRINT_META = [ 'print' ];

    static var AD_META = [ 'added', 'ad', 'a', ':added', ':ad', ':a' ];
    static var RM_META = [ 'removed', 'rm', 'r',':removed', ':rm', ':r' ];
    static var UPD_META = [ 'update', 'up', 'u', ':update', ':up', ':u' ];
    static var PARALLEL_META =  ':parallel' ;
    static var FORK_META =  ':fork' ;
    static var JOIN_META =  ':join' ;

    public static var systemIndex = -1;
    public static var systemIds = new Map<String, Int>();


    static function notSkipped(field:Field) {
        return !containsMeta(field, SKIP_META);
    }

    static function containsMeta(field:Field, metas:Array<String>) {
        return field.meta
            .exists(function(me) {
                return metas.exists(function(name) return me.name == name);
            });
    }

    static var _printer = new Printer();

    public static function build(debug: Bool = false) {
        var fields = Context.getBuildFields();

        var ct = Context.getLocalType().toComplexType();

        var index = ++systemIndex;

        systemIds[ct.followName()] = index;

        // prevent wrong override
        for (field in fields) {
            switch (field.kind) {
                case FFun(func): 
                    switch (field.name) {
                        case '__update__':
                            Context.error('Do not override the `__update__` function! Use `@update` meta instead! More info at README example', field.pos);
                        case '__activate__':
                            Context.error('Do not override the `__activate__` function! `onactivate` can be overrided instead!', field.pos);
                        case '__deactivate__':
                            Context.error('Do not override the `__deactivate__` function! `ondeactivate` can be overrided instead!', field.pos);
                        default:
                    }
                default:
            }
        }


        function notNull<T>(e:Null<T>) return e != null;

        // @meta f(a:T1, b:T2, deltatime:Float) --> a, b, __dt__
        function metaFuncArgToCallArg(a:FunctionArg) {
            return switch (a.type.followComplexType()) {
                case macro:StdTypes.Float : macro __dt__;
                case macro:StdTypes.Int : macro __entity__;
                case macro:ecs.Entity : macro __entity__;
                default: macro $i{ a.name };
            }
        }

        function metaFuncArgIsEntity(a:FunctionArg) {
            return switch (a.type.followComplexType()) {
                case macro:StdTypes.Int, macro:ecs.Entity : true;
                default: false;
            }
        }

        function refComponentDefToFuncArg(c:{ cls:ComplexType }, args:Array<FunctionArg>) {
            var copmonentClsName = c.cls.followName();
            var a = args.find(function(a) return a.type.followName() == copmonentClsName);
            if (a != null) {
                return arg(a.name, a.type);
            } else {
                return arg(c.cls.typeFullName().toLowerCase(), c.cls);
            }
        }

        function metaFuncArgToComponentDef(a:FunctionArg) {


            return switch (a.type.followComplexType()) {
                case macro:StdTypes.Float : null;
                case macro:StdTypes.Int : null;
                case macro:ecs.Entity : null;
                default: 
                    var mm = a.meta.toMap();
                    mm.exists(":local") ? null : { cls: a.type.followComplexType() };
            }
        }

        var definedViews = new Array<{ name:String, cls:ComplexType, components:Array<{ cls:ComplexType }> }>();

        // find and init manually defined views
        fields
            .filter(notSkipped)
            .iter(function(field) {
                switch (field.kind) {
                    // defined var only
                    case FVar(cls, _) if (cls != null): {
                        var complexType = cls.followComplexType();
                        switch (complexType) {
                            // tpath only
                            case TPath(_): {
                                var clsName = complexType.followName();
                                // if it is a view, it was built (and collected to cache) when followComplexType() was called
                                if (viewCache.exists(clsName)) {
                                    // init
                                    field.kind = FVar(complexType, macro $i{clsName}.inst());

                                    definedViews.push({ name: field.name, cls: complexType, components: viewCache.get(clsName).components });
                                }
                            }
                            default:
                        }
                    }
                    default:
                }
            } );

        // find and init meta defined views
        fields
            .filter(notSkipped)
            .filter(containsMeta.bind(_, UPD_META.concat(AD_META).concat(RM_META)))
            .iter(function(field) {
                switch (field.kind) {
                    case FFun(func): {

                        var components = func.args.map(metaFuncArgToComponentDef).filter(notNull);
                        var worlds = metaFieldToWorlds(field);
                        
                        if (components.length > 0) {

                            var viewClsName = getViewName(components, worlds);
                            var view = definedViews.find(function(v) return v.cls.followName() == viewClsName);

                            if (view == null) {
                                var viewComplexType = getView(components, worlds);

                                // instant define and init
                                fields.push(fvar([], [], viewClsName.toLowerCase(), viewComplexType, macro $i{viewClsName}.inst(), Context.currentPos()));

                                definedViews.push({ name: viewClsName.toLowerCase(), cls: viewComplexType, components: viewCache.get(viewClsName).components });
                            }

                        }
                    }
                    default:
                }
            } );


        function procMetaFunc(field:Field) : UpdateRec{
            return switch (field.kind) {
                case FFun(func): {
                    var funcName = field.name;
                    var funcCallArgs = func.args.map(metaFuncArgToCallArg).filter(notNull);
                    var components = func.args.map(metaFuncArgToComponentDef).filter(notNull);
                    var worlds = metaFieldToWorlds(field);

                    if (components.length > 0) {
                        // view iterate

                        var viewClsName = getViewName(components,worlds);
                        var view = definedViews.find(function(v) return v.cls.followName() == viewClsName);
                        var viewArgs = [ arg('__entity__', macro:ecs.Entity) ].concat(view.components.map(refComponentDefToFuncArg.bind(_, func.args)));

                        { name: funcName, rawargs: func.args, meta:field.meta.toMap(), args: funcCallArgs, view: view, viewargs: viewArgs, type: VIEW_ITER };

                    } else {

                        if (func.args.exists(metaFuncArgIsEntity)) {
                            // every entity iterate
                            Context.warning("Are you sure you want to iterate over all the entities? If not, you should add some components or remove the Entity / Int argument", field.pos);

                            { name: funcName,  rawargs: func.args, meta:field.meta.toMap(), args: funcCallArgs, view: null, viewargs: null, type: ENTITY_ITER };

                        } else {
                            // single call
                            { name: funcName,  rawargs: func.args, meta:field.meta.toMap(), args: funcCallArgs, view: null, viewargs: null, type: SINGLE_CALL };
                        }

                    }
                }
                default: null;
            }
        }


        // define new() if not exists (just for comfort)
        if (!fields.exists(function(f) return f.name == 'new')) {
            fields.push(ffun([APublic], 'new', null, null, null, Context.currentPos()));
        }


        var ufuncs = fields.filter(notSkipped).filter(containsMeta.bind(_, UPD_META)).map(procMetaFunc).filter(notNull);
        var afuncs = fields.filter(notSkipped).filter(containsMeta.bind(_, AD_META)).map(procMetaFunc).filter(notNull);
        var rfuncs = fields.filter(notSkipped).filter(containsMeta.bind(_, RM_META)).map(procMetaFunc).filter(notNull);
        var listeners = afuncs.concat(rfuncs);

        // define signal listener wrappers
        listeners.iter(function(f) {
            fields.push(fvar([], [], '__${f.name}_listener__', TFunction(f.viewargs.map(function(a) return a.type), macro:Void), null, Context.currentPos()));
        });

        var uexprs = []
            #if echoes_profiling
            .concat(
                [
                    macro var __timestamp__ = Date.now().getTime()
                ]
            )
            #end
            .concat(
                ufuncs.map(function(f) {
                    return switch (f.type) {
                        case SINGLE_CALL: {
                            macro $i{ f.name }($a{ f.args });
                        }
                        case VIEW_ITER: {
                            var maxParallel = PUnknown;
                            if (f.meta.exists(":parallel")) {
                                // TODO - Make it run in parallel :)
                                var pm = f.meta[":parallel"][0]; //only pay attention to the first one
                                if (pm.length > 0) {
                                    var pstr = pm[0].getStringValue();
                                    if (pstr != null) {
                                        maxParallel = switch (pstr.toUpperCase()) {
                                            case "FULL": PFull; 
                                            case "HALF": PHalf;
                                            case "DOUBLE": PDouble;
                                            default: PUnknown;
                                        }
                                    } 

                                    if (maxParallel == PUnknown) {
                                        try  maxParallel = PCount(pm[0].getNumericValue()) catch (x){
                                            throw 'Could not parse parallel value ${x.message}';
                                        }
                                    }
                                    
                                } 
                            }
                            
                            var callTypeMap = new Map<String, Expr>();
                            var callNameMap = new Map<String, Expr>();
                            callTypeMap["Float".asComplexType().followComplexType().typeFullName()] = macro __dt__;
                            callTypeMap["ecs.Entity".asComplexType().followComplexType().typeFullName()] = macro __entity__;
                            for (c in f.view.components) {
                                var ct = c.cls.typeFullName();
                                var info = getComponentContainerInfo(c.cls);
                                callTypeMap[ct] = info.getGetExpr(macro __entity__,  info.fullName + "_inst");
                            }

                            var cache = f.view.components.map(function(c) {
                                var info = getComponentContainerInfo(c.cls);
                                return info.getCacheExpr( info.fullName + "_inst" );
                            });

                            for (a in f.rawargs) {
                                var am = a.meta.toMap();
                                var local = am.get(":local");
                                if (local != null && local.length > 0 && local[0].length > 0) {
                                    callNameMap[a.name] = macro $i{"__l_" + a.name};
                                    cache.push( ("__l_" + a.name).define(local[0][0]));
                                }
                            }

                            var remappedArgs = f.rawargs.map( (x) -> {
                                var ctn = x.type.followComplexType().typeFullName();
                                if (callNameMap.exists(x.name)) {
                                    return callNameMap[x.name];
                                }
                                if (callTypeMap.exists(ctn)) {
                                    return callTypeMap[ctn];
                                }
                                
                                throw 'No experession for type ${ctn}';
                            });

                            
                            
                            var loop = macro 
                                for (__entity__ in $i{ f.view.name }.entities) {
                                    $i{ '${f.name}' }($a{ remappedArgs });
                                }

                            cache.concat([loop]).toBlock();
                        }
                        case ENTITY_ITER: {
                            macro for (__entity__ in ecs.Workflow.entities) {
                                $i{ f.name }($a{ f.args });
                            }
                        }
                    }
                })
            )
            #if echoes_profiling
            .concat(
                [
                    macro this.__updateTime__ = Std.int(Date.now().getTime() - __timestamp__)
                ]
            )
            #end;

        var aexpr = macro if (!activated) $b{
            [].concat(
                [
                    macro activated = true
                ]
            )
            .concat(
                // init signal listener wrappers
                listeners.map(function(f) {
                    // DCE is eliminating this on 'full'
                    var fwrapper = { expr: EFunction(FunctionKind.FAnonymous, { args: f.viewargs, ret: macro:Void, expr: macro $i{ f.name }($a{ f.args }) }), pos: Context.currentPos()};
                    return macro $i{'__${f.name}_listener__'} = $fwrapper;
                })
            )
            .concat(
                // activate views
                definedViews.map(function(v) {
                    return macro $i{ v.name }.activate();
                })
            )
            .concat(
                // add added-listeners
                afuncs.map(function(f) {
                    return macro $i{ f.view.name }.onAdded.add($i{ '__${f.name}_listener__' });
                })
            )
            .concat(
                // add removed-listeners
                rfuncs.map(function(f) {
                    return macro $i{ f.view.name }.onRemoved.add($i{ '__${f.name}_listener__' });
                })
            )
            .concat(
                // call added-listeners
                afuncs.map(function(f) {
                    return macro $i{ f.view.name }.iter($i{ '__${f.name}_listener__' });
                })
            )
            .concat(
                [
                    macro onactivate()
                ]
            )
        };


        var dexpr = macro if (activated) $b{
            [].concat(
                [
                    macro activated = false,
                    macro ondeactivate()
                ]
            )
            .concat(
                // deactivate views
                definedViews.map(function(v) {
                    return macro $i{ v.name }.deactivate();
                })
            )
            .concat(
                // remove added-listeners
                afuncs.map(function(f) {
                    return macro $i{ f.view.name }.onAdded.remove($i{ '__${f.name}_listener__' });
                })
            )
            .concat(
                // remove removed-listeners
                rfuncs.map(function(f) {
                    return macro $i{ f.view.name }.onRemoved.remove($i{ '__${f.name}_listener__' });
                })
            )
            .concat(
                // null signal wrappers 
                listeners.map(function(f) {
                    return macro $i{'__${f.name}_listener__'} = null;
                })
            )
        };


        if (uexprs.length > 0) {

            fields.push(ffun([APublic, AOverride], '__update__', [arg('__dt__', macro:Float)], null, macro $b{ uexprs }, Context.currentPos()));

        }

        fields.push(ffun([APublic, AOverride], '__activate__', [], null, macro { $aexpr; }, Context.currentPos()));
        fields.push(ffun([APublic, AOverride], '__deactivate__', [], null, macro { $dexpr; }, Context.currentPos()));

        // toString
        fields.push(ffun([AOverride, APublic], 'toString', null, macro:String, macro return $v{ ct.followName() }, Context.currentPos()));


        var clsType = Context.getLocalClass().get();
        
        if (debug || PRINT_META.exists(function(m) return clsType.meta.has(m))) {
            switch (Context.getLocalType().toComplexType()) {
                case TPath(p): {
                    var td:TypeDefinition = {
                        pack: p.pack,
                        name: p.name,
                        pos: clsType.pos,
                        kind: TDClass(tpath("ecs", "System")),
                        fields: fields
                    }
                    trace(new Printer().printTypeDefinition(td));
                }
                default: {
                    Context.warning("Fail @print", clsType.pos);
                }
            }
        }
        //trace("New Func");
        for (f in fields) {
          //  trace(_printer.printField(f));
        }

        return fields;
    }

}

@:enum abstract MetaFuncType(Int) {
    var SINGLE_CALL = 1;
    var VIEW_ITER = 2;
    var ENTITY_ITER = 3;
}

#end
