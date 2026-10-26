#!/bin/sh
name="perry.cuabench.$1"; log="$2"; shift 2
dir="$HOME/Honey/perry-cua-scratch/run"
plist="$dir/$name.plist"
rm -f "$log" "$dir/$name.done"
{
echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
echo "<key>Label</key><string>$name</string><key>ProgramArguments</key><array>"
echo "<string>/bin/sh</string><string>-c</string><string>"
printf '%s ' "$@"
echo "; echo done > $dir/$name.done</string></array>"
echo "<key>StandardOutPath</key><string>$log</string><key>StandardErrorPath</key><string>$log</string><key>RunAtLoad</key><true/><key>ProcessType</key><string>Interactive</string>"
echo "<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>"
echo '</dict></plist>'
} > "$plist"
launchctl bootout "gui/$(id -u)/$name" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$plist" || exit 1
n=0
while [ ! -f "$dir/$name.done" ] && [ $n -lt 1800 ]; do sleep 1; n=$((n+1)); done
launchctl bootout "gui/$(id -u)/$name" 2>/dev/null
rm -f "$plist"
cat "$log"
