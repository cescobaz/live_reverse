# Changelog

## v0.1.0 (unreleased)

First release.

- `use LiveReverse` behaviour with the optional callbacks `mount/4`,
  `unmount/2`, `handle_params/3`, `handle_info/2`, `handle_event/3` and
  `handle_async/3`.
- Generated `on_mount/4`, attaching hooks only for the callbacks the module
  defines.
- `attach: :each | :once` option for modules listed in several `on_mount`
  entries.
- `LiveReverse.install/4` and `LiveReverse.detach/3` to add and remove
  features at runtime.
