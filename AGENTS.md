# Project structure
* `src/` -- main codebase
* `docs/skills/lazy-circus/` -- skill about how to use this library


# Codebase navigation
* Use LSP tools (`goToDefinition`, `findReferences`, `hover`) to navigate code. They are more accurate and faster than grep/glob search. LSP is available for Haskell files.

# Technical details
* Before building or running tests always run `hpack`. It updates the `cabal` file needed for project management.
* Do not modify `exposed-modules` in `package.yaml`. The project uses discovery for modules via `hpack`.


# Tests
Tests are run with `stack test`.


## Function Documentation

Every **exported** function has a Haddock comment with description and contracts.

```haskell
-- | What the function does in general terms + important usage details.
-- PRE-CONTRACT: Conditions that must hold before calling, or None.
-- POST-CONTRACT: Properties guaranteed after return, or None.
functionName :: Type -> Type
functionName = ...
```

# Documentation

### PRE-CONTRACT and POST-CONTRACT

These capture invariants the type system cannot express:
- **PRE-CONTRACT**: caller obligations — "must be called after `initDB`", "input list must be non-empty"
- **POST-CONTRACT**: guarantees to the caller — "result is sorted", "returned handle is open"

If there are none, omit the line (no need to write `None` explicitly).

### Where-helpers

Local helpers in `where` blocks are documented with a Haddock `-- |` line directly above:

```haskell
-- | Calculates the probability of an element appearing in a series.
-- POST-CONTRACT: Result is in range [0.0, 1.0]
computeProbability :: Eq a => a -> [a] -> Double
computeProbability element series =
    fromIntegral (count series) / fromIntegral (length series)
  where
    -- | counts elements equal to the target
    count = length . filter (== element)
```

### Examples

```haskell
-- | Sums 2 numbers.
aPlusB :: Int -> Int -> Int
aPlusB a b = a + b
```

```haskell
-- | Draws a triangle defined by 3 points.
-- PRE-CONTRACT: Must be called only after `startDrawMode`.
drawTriangle :: Point -> Point -> Point -> IO ()
drawTriangle pointA pointB pointC = do
    draw pointA pointB
    draw pointB pointC
    draw pointC pointA
```

---

## Type Documentation

Every type declaration (`data`, `newtype`, `type`) has a Haddock comment.

```haskell
-- | Description of the type and what it represents.
data TypeName = ...
```

### Named fields

Use the type name as a prefix for all field names. Document each field with `-- ^`.

```haskell
-- | An animal in the zoo, with identity and physical properties.
data Animal = Animal
    { animalName       :: Text      -- ^ human-friendly display name
    , animalKind       :: AnimalKind -- ^ taxonomic kind
    , animalNumOfLegs  :: Int       -- ^ number of legs
    }
```

### Multiple constructors

Constructors are separated vertically. If any constructor has unnamed fields, document each constructor with `-- ^`:

```haskell
-- | Actions the player character can take each turn.
data GameAction
    = Move Direction  -- ^ Move character one step in the given direction
    | Attack          -- ^ Attack using CurrentAim as direction
```

If all constructors are simple enum-style (no fields), `-- ^` annotations are optional:

```haskell
-- | Broad taxonomic groupings used for zoo exhibit organisation.
data AnimalKind
    = Mammal
    | Reptile
    | Bird
```

---

## Typeclass Documentation

Typeclass declarations have a Haddock comment with laws documented inline.

```haskell
-- | Description of what the typeclass abstracts.
-- LAWS:
--   law name: formal or informal law statement
--   law name: formal or informal law statement
class ClassName a where
    method :: a -> Result
    -- | optional method with default, explain the default
    optionalMethod :: a -> Other
    optionalMethod = ...
```

`LAWS:` is required if the typeclass has laws. If it has none, omit the section entirely. Document default method implementations with `-- |`.

### Example

```haskell
-- | Things that can be rendered to the current draw context.
-- LAWS:
--   idempotent: draw x >> draw x = draw x
class Drawable a where
    draw :: a -> IO ()
    -- | Draw at specific coordinates; default delegates to draw, ignoring position
    drawAt :: Point -> a -> IO ()
    drawAt _ = draw
```

---

## Instance Documentation

Every typeclass instance has a Haddock comment.

```haskell
-- | Brief note on the instance — what it does or why it exists here.
-- LAW: law name: holds / does not hold because ...
instance ClassName TypeConstructor where
    ...
```

### LAW annotation

Document non-trivial law compliance. If the laws hold trivially by construction, omit. If a law is intentionally not satisfied (rare), document why.

### Placement

- Instance for a **new type with an existing class** → place in the same file as the type
- Instance for a **new class with an existing type** → place in the same file as the class
- **Orphan instance** (type and class from different libraries) → place in a dedicated file that is guaranteed to be imported; mark with `-- ORPHAN` in the Haddock line

### Examples

```haskell
-- | Renders as "Name (Kind)"
instance Show Animal where
    show Animal{..} = animalName <> " (" <> show animalKind <> ")"
```

```haskell
-- | ORPHAN: Animal is from Zoo.Types, Drawable is from Render.Class
-- LAW: idempotent: holds — draw calls are referentially transparent
instance Drawable Animal where
    draw animal = renderSprite (animalKind animal)
```
