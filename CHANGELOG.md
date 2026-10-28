# Changelog

## v0.1.0 (unreleased)

First release.

- `use LiveReverse` behaviour with the optional callbacks `mount/4`,
  `unmount/2`, `handle_params/4`, `handle_info/3`, `handle_event/4` and
  `handle_async/4`. The `handle_*` callbacks take the `on_mount` argument
  first.
- Generated `on_mount/4`, attaching hooks only for the callbacks the module
  defines.
- `attach: :each | :once` option for modules listed in several `on_mount`
  entries: one set of hooks per argument, or one shared set that gets the
  list of every argument (also returned by `LiveReverse.args/2`).
- `LiveReverse.install/4` and `LiveReverse.detach/3` to add and remove
  features at runtime.
- `LiveReverse.inline/2` to define a feature module inside a LiveView and
  mount it in place, with the `:key`, `:arg` and `:attach` options.
