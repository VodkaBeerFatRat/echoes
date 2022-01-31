# hcqe

Super lightweight Entity Component System framework for Haxe. 
Initially created to learn the power of macros. 
Focused to be simple and fast. 
Inspired by other haxe ECS frameworks, especially [EDGE](https://github.com/fponticelli/edge), [ECX](https://github.com/eliasku/ecx), [ESKIMO](https://github.com/PDeveloper/eskimo) and [Ash-Haxe](https://github.com/nadako/Ash-Haxe)
Extended to hcqe - For performance improvements with struct only types

#### Acknowledgement by onehundredfeet
The original vision by [deepcake](https://github.com/deepcake/echo) was fantastic.  A macro driven ECS that was aimed at ease of use and performance. It had a few drawbacks I wanted to fix. 

#### Challenges & Solutions
- It had a single world.  This is fine for most applications, but world partitions are sometimes necessary, especially in multiplayer games. (Solved with world flags feature)
- Allocated objects are manually pooled (Solved pool builder feature)
- Singleton components are not natively supported (Solved - Two different features)
- Ability to customize the storage type per component (Solved with @:storage feature)
- The performance at scale with lots of views makes adding and removing entities expensive. I plan on adding a factory system to speed the creation of entities. (1st pass done - Needs a revision)
- Struct types in Haxe are still allocated individually.  This makes streamlined processing difficult.  For large element counts, you are constantly cache missing.  
- Parallelism wasn't natively supported (First pass design complete)

The first version of this will primarily target HashLink, but may be extended to others.

### Overview
 * Component is an instance of `T:Any` class. For each class `T` will be generated a global component container, where instance of `T` is a value and `Entity` is a key. 
 * `Entity` in that case is just an abstract over the `Int`, but with the ability to work with it as with a set of components like in other regular ECS frameworks. 
 * `View<T1, T2, TN>` is a collection of entities containing all components of the required types `T1, T2, TN`. Views are placed in Systems. 
 * `System` is a place for processing a certain set of data represented by views. 
 * To organize systems in phases can be used the `SystemList`. 
* `World` is a binding mechanism to allow views and systems to opperate on a subset of entities. A View (and a function in a System) can be associated with any number of Worlds.  When an Entity is created, it can be associated with any number of worlds.  At the moment, there is a maximum of 32 worlds.  Views will only include Entities that are associated with `ANY` of the worlds it can view.
* `Pool` a pool is a static container that can be used to speed up allocations using a rent/retire paradigm. Call a static rent to get a new instance and then retire on that instance to return it to the pool
* `Workflow` a global class used to access common features such as a singleton

#### Note: Currently requires a compiler macro to handle all setup. Add into your .hxml or command line

--macro hcqe.core.macro.Global.setup()

#### Example
```haxe
import hcqe.SystemList;
import hcqe.Workflow;
import hcqe.Entity;


// Can use vanilla classes with no annotation
class MediumComponent {

}

@:storage(FAST) // This is the default
#if !macro @:build(hcqe.core.macro.PoolBuilder.arrayPool()) #end // Implicitly adds rent & retire
//@:no_autoretire  // default is true | will automatically return the object to the pool on being removed from the entity
class SmallComponent {
    // Implicitly added by the pool builder
    // static function rent() : SmallComponent 
    // function retire()
    
    function new() {

    }

    @:pool_factory  // overrides the default 'new' 
    static function factory() : SmallComponent{
      return new SmallComponent();  // Example - This is identical to the generated default factory
    }

    @:pool_retire  // callback when retiring
    function onRetire() {

    }
}

@:storage(COMPACT)
class HeavyComponent {
  public function new(){}

  @:onadd
    function onAdd() {
      // Custom logic when a component is added from an entity
    }

  @:onremove
    function onRemove() {
      // Custom logic when a component is removed from an entity
    }
}

@:storage(SINGLETON)  // Simply specifies the storage capacity, does not affect the behaviour
class SingletonComponent {
  public function new(){}
}

// 0 is assumed to mean 'empty' with Int abstracts. This may mean that with some cases it is not possible to use this approach.
abstract MicroComponent(Int) from Int to Int {
  public function new(x : Int) {
    this = x;
  }
}

class Example {
  final FIELDS = 1;
  final FOREST = 2;
  final WORLDS_FIELDS = 1 << FIELDS;
  final WORLDS_FOREST = 1 << FOREST;

  static function main() {
    var physics = new SystemList()
      .add(new Movement())
      .add(new CollisionResolver());

    Workflow.addSystem(physics);
    Workflow.addSystem(new Render()); // or just add systems directly

    var john = createRabbit(0, 0, 1, 1, 'John', WORLDS_FIELDS); // Only in the forest
    var jack = createRabbit(5, 5, 1, 1, 'Jack', WORLDS_FIELDS | WORLDS_FOREST); // In both worlds

    trace(jack.exists(Position)); // true
    trace(jack.get(Position).x); // 5
    jack.remove(Position); // oh no!
    jack.add(new Position(1, 1)); // okay

    // THIS IS TWO FEATURES 
    // - the singleton() on workflow is a global entity
    // - the SingletonComponent is one that only allows for one to every be added to an entity
    Workflow.singleton().add( new SingletonComponent() ); // Only one can be added globally at any one time

// also somewhere should be Workflow.update call on every tick
    Workflow.update(1.0);
  }
  static function createTree(x:Float, y:Float) {
    return new Entity()   // Trees are present in all worlds
      .add(new Position(x, y))
      .add(new Sprite('assets/tree.png'))
      .add(new MediumComponent(1))
      .add(new HeavyComponent());
  }
  static function createRabbit(x:Float, y:Float, vx:Float, vy:Float, name:Name, worlds:Int) {
    var pos = new Position(x, y);
    var vel = new Velocity(vx, vy);
    var spr = new Sprite('assets/rabbit.png');
    return new Entity(worlds).add(pos, vel, spr, name, SmallComponent.rent()); // rabbits can be in world specified
  }
}

@:forward
abstract Name(String) from String to String {
  public function new(name:String) this = name;
}

class Movement extends hcqe.System {
  // @update-functions will be called for every entity that contains all the defined components;
  // All args are interpreted as components, except Float (reserved for delta time) and Int/Entity;
  @:update function updateBody(pos:Position, vel:Velocity, dt:Float, entity:Entity) {
    pos.x += vel.x * dt;
    pos.y += vel.y * dt;
  }

  //Can narrow the scope of the update to only entities that are present in a world set
  @:worlds(WORLDS_FOREST) // These are bit flags.  The string is evaulate as an expression
  @update function inForest(name:Name) {
    trace('${name} is in the forest'); // Will display Jack
  }

  // Worlds can be strings or constant string expressions if using compiler only @:
  @:worlds(WORLDS_FIELDS) // These are bit flags.  The string is evaulate as an expression
  @:update function inFields(name:Name) {
    trace('${name} is in the fields'); // Will display Jack & John
  }

  // If @update-functions are defined without components, 
  // they are called only once per system's update;
  @:update function traceHello(dt:Float) {
    trace('Hello!');
  }
  // The execution order of @update-functions is the same as the definition order, 
  // so you can perform some preparations before or after iterating over entities;
  @:update function traceWorld() {
    trace('World!');
  }
}

class NamePrinter extends hcqe.System {
  // All of necessary for meta-functions views will be defined and initialized under the hood, 
  // but it is also possible to define the View manually (initialization is still not required) 
  // for additional features such as counting and sorting entities;
  var named:View<Name>;

  @:update function sortAndPrint() {
    named.entities.sort((e1, e2) -> e1.get(Name) < e2.get(Name) ? -1 : 1);
    // using Lambda
    named.entities.iter(e -> trace(e.get(Name)));
  }
}

class Render extends hcqe.System {
  var scene:DisplayObjectContainer;
  // There are @a, @u and @r shortcuts for @added, @update and @removed metas;
  // @added/@removed-functions are callbacks that are called when an entity is added/removed from the view;
  @:a function onEntityWithSpriteAndPositionAdded(spr:Sprite, pos:Position) {
    scene.addChild(spr);
  }
  // Even if callback was triggered by destroying the entity, 
  // @removed-function will be called before this happens, 
  // so access to the component will be still exists;
  @:r function onEntityWithSpriteAndPositionRemoved(spr:Sprite, pos:Position, e:Entity) {
    scene.removeChild(spr); // spr is still not a null
    trace('Oh My God! They removed ${ e.exists(Name) ? e.get(Name) : "Unknown Sprite" }!');
  }

  // PARALLEL API NOT IMPLEMENTED YET
  @:parallel(FULL) // | @:p(FULL) - Valid values FULL | DOUBLE | HALF | # - Will create threads to call this function in parallel according to the number specifed in the parameters.  Will collect all threads before continuing.
  @:bucket(5) // | @:b(5) Specifies the parallel bucketing size valid values MAX | # - Max will take total / threads
  @:fork(SPRITE_UPDATE) // - Named synchronization - Will split off this update in another thread and continue processing other updates, can be combined with @:parallel
  @:u inline function updateSpritePosition(spr:Sprite, pos:Position) {
    spr.x = pos.x;
    spr.y = pos.y;
  }

  // PARALLEL API NOT IMPLEMENTED YET
  @:join(SPRITE_UPDATE) // - Will wait until the corresponding fork is completed before running this function
  @:u inline function afterSpritePositionsUpdated() {
    // rendering, etc
  }
}
```

#### Also
There is also exists a few additional compiler flags:
 * `-D hcqe_profiling` - collecting some more info in `Workflow.info()` method for debug purposes
 * `-D hcqe_report` - traces a short report of built components and views

### Install
```haxelib git hcqe https://github.com/onehundredfeet/hcqe.git```
