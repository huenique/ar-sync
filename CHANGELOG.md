# Changelog

## v1.0.3

- **Fix:** the viewing laptop no longer pauses sync when nobody sold anything on it.
  - Before this, opening a shift (starting cash), a Z report, or Aronium updating a product or customer while it was open counted as "sales made here". The pause showed "Sales were recorded on this laptop" for days.
  - Now only new receipts, receipt lines or payments since the last restore pause sync. The restore stamp records those counts and highest Ids as its baseline.
- A pause left by an older version with no sale behind it is lifted automatically on the next check. A pause with a real sale behind it stays.

## v1.0.2

- **Fix:** the auto-updater failed and rolled back on laptops whose Windows user folder has a space, such as "M.O FLORES CONS".
  - Windows gives such a folder a short name like `M8F8E~1.OFL`. The updater mixed the short and long forms when working out where each file goes, so files landed in a stray `age\` folder.
  - Paths are now normalized and relative paths are built from the folder walk.
  - Laptops on v1.0.0 or v1.0.1 still have the broken updater, so install v1.0.2 once with `install.ps1`. Updates work by themselves after that.

## v1.0.1

- **Fix:** Aronium now reopens in its own folder after **Update now** or **Take over**. Before this, it started in the folder of whatever reopened it, often System32. It then couldn't find its `Lang\` files, so every label showed a raw key like "Order.Subtotal".
  - If a laptop already shows those keys, close Aronium and open it again from its usual shortcut.

## v1.0.0

- First release: one-writer sync, takeover and hand-back, and self-update from GitHub releases.
