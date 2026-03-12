# plots

A plot world system for Luanti inspired by 'PlotSquared' for Minecraft.

## What It Does

- Lets players claim plots to build on.
- Plot protection + access lists (`add`, `trust`, `deny`).
- Multi-plot limits via privilege `plots.multiple.<number>`
- Admin privileges: `plots.admin.others` (interact with others' claimed plots), `plots.admin.road` (interact with roads).

File: `data/config.json`

## Notable options

- `plot_size`: buildable plot width/length.
- `plot_gap`: road/gap space between plots.
- `shape`: plot shape (`square` or `sphere`).
- `grid_world_size`: total managed plot-world size.
- `origin`: center point of the plot grid.
- `dimension`: Y-range where plots/protection are active.
- `max_plots_per_player`: default claim limit (before privileges).
- `road_node`: road block material.
- `unowned_plot_node`: fill block for unclaimed plots.
- `floor_node`: base floor block used by plot generation.

## Commands

- `/plot (create|auto|claim)`
- `/plot info [plot_id]`
- `/plot (h|home) [index] [player]`
- `/plot home [index] [player]`
- `/plot hid <plot_id>`
- `/plot add <player>`
- `/plot trust <player>`
- `/plot (revoke|remove) <player>`
- `/plot undeny <player>`
- `/plot deny <player>`
- `/plot kick <player>`
- `/plot transfer <player>`
- `/plot clear`
- `/plot delete`

- `/p ...` (alias for `/plot ...`)