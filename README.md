# DChronos

Independent manifest-based Roblox Lua loader scaffold.

## Important

This project contains only original DChronos loader code and an empty/example
module structure. It does not include third-party game scripts.

## Setup

1. Create a new GitHub repository named:

   `DChronos`

2. Open `loader.lua` and change:

   ```lua
   local REPO_OWNER = "elyoenaia-hub"
   ```

   to your GitHub username.

3. Open:

   `modules/manifest.json`

   and replace `elyoenaia-hub` in `baseUrl`.

4. Upload this project to the `main` branch.

## Public loader

After replacing your username:

```lua
loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/elyoenaia-hub/DChronos/main/loader.lua"
))()
```

## Repository layout

```text
DChronos/
├── loader.lua
├── modules/
│   ├── manifest.json
│   └── example.lua
├── README.md
├── LICENSE
└── VERSION
```

## Adding your own module

Put your file inside `modules/`, for example:

```text
modules/my-game.lua
```

Then add an entry to `modules/manifest.json`:

```json
{
  "name": "My Game",
  "enabled": true,
  "creatorId": 123456,
  "creatorFallback": true,
  "placeIds": [],
  "universeIds": [],
  "file": "my-game.lua"
}
```

For creators that own multiple supported games, prefer `placeIds` and/or
`universeIds`, and set `creatorFallback` to `false`.

## Resolution priority

1. PlaceId
2. UniverseId (`game.GameId`)
3. CreatorId fallback

## DChronos v1.0.0 features

- Independent project branding
- Manifest-based module registry
- Lightweight loading interface
- HTTP retries
- JSON validation
- Compile/runtime error reporting
- Duplicate-run guard
- PlaceId / UniverseId / CreatorId detection
