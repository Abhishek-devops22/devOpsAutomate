# launchd schedule (macOS)

`com.devopsautomate.dockercleanup.plist` runs `cleanup-idle-resources.sh
--dry-run` daily at 2:00 AM — a dry run only, nothing is deleted
automatically. Results land in `scripts/docker/logs/`; run the script
manually with `-y` when you want to actually clean up what it flagged.

Paths inside the plist are absolute and specific to this machine — update
them if you copy this to another box.

## Install

```bash
cp com.devopsautomate.dockercleanup.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.devopsautomate.dockercleanup.plist
```

## Manage

```bash
# stop/unload
launchctl bootout gui/$(id -u)/com.devopsautomate.dockercleanup

# reload after editing the plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.devopsautomate.dockercleanup.plist

# check it's loaded
launchctl list | grep devopsautomate
```

Note: launchd agents only fire while you're logged in — if the Mac is
asleep or logged out at 2 AM, it runs shortly after you next log in/wake,
rather than being skipped silently.
