-- Records the disk image window into the image itself: size, icon layout and
-- the grid background. Only the Finder can write these, hence the AppleScript.
-- Window content is 640x400, matching packaging/dmg-background.tiff.
tell application "Finder"
	tell disk "OpenBattery"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 840, 548}

		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 128
		set text size of viewOptions to 12
		set background picture of viewOptions to file ".background:background.tiff"

		set position of item "OpenBattery.app" of container window to {160, 190}
		set position of item "Applications" of container window to {480, 190}

		close
		open
		update without registering applications
		delay 1
	end tell
end tell
