# plots

Plot world system for Luanti, inspired by PlotSquared-style plot management.

This mod creates build plots in a separate area, teleports players to owned plots, and enforces plot-based protection/access rules.

## Requirements

- `default`

## Configuration

Configuration is loaded from:

`data/config.json`

### Config Fields

- `max_plots_per_player`: Max owned plots per player.
- `plot_size`: Plot diameter/width used by layout logic.
- `plot_gap`: Gap between neighboring plot cells.
- `shape`: `square` or `sphere`.
- `grid_columns`: Number of columns before wrapping to next row.
- `origin`: Grid anchor position (`x`, `y`, `z`).
- `spawn`: Global safe spawn used for denied/kicked players.
- `dimension`: Allowed plot world Y-range (`y_min`, `y_max`).
- `build_height`: Vertical build height above plot center.
- `build_depth`: Vertical depth below plot center used by terrain/protection bounds.
- `floor_node`: Fallback floor node for safe teleport pads.
- `wall_node`: Border/void wall node (defaults to `plots:void`).
- `terrain_top_node`, `terrain_dirt_node`, `terrain_stone_node`: Terrain regeneration nodes.
- `terrain_grass_plant_chance`: Chance to place grass decorations on regenerated terrain.
- `border_enabled`: Enable perimeter wall/border logic.
- `confirm_ttl_seconds`: Confirm GUI timeout for destructive actions.
- `deny_check_interval`: Seconds between deny enforcement checks.

## Commands

Use `/plot` to print help.

- `/plot create`
- `/plot auto`
- `/plot deny <player>`
- `/plot kick <player>`
- `/plot delete`
- `/plot clear`
- `/plot add <player>`
- `/plot trust <player>`
- `/plot remove <player>`
- `/plot revoke <player>`
- `/plot h [index] [player]`
- `/plot home [index] [player]`
- `/plot hid <plot_id>`

## Access Rules

- Owner can always build on own plot.
- `trust`: player can build anytime.
- `add`: player can build only while owner is physically on that plot.
- `deny`: player cannot visit/build and is periodically kicked out.
