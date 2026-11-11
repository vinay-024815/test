on run argv
  set extensionPath to item 1 of argv
  set setupMode to item 2 of argv

  set chromeWasClosed to false
  tell application "Google Chrome"
    activate
    if (count of windows) is 0 then
      set profileWindow to make new window
      set URL of active tab of profileWindow to "chrome://profile-picker/"
      set chromeWasClosed to true
    end if
  end tell
  if chromeWasClosed then
    display dialog "Chrome was closed. Select the intended profile in Chrome, then return here and click Continue." buttons {"Cancel", "Continue"} default button "Continue" with title "Credential Vault setup"
  end if

  tell application "Google Chrome"
    activate
    set windowTitles to {}
    repeat with i from 1 to (count of windows)
      try
        set end of windowTitles to (i as text) & ". " & (title of active tab of window i)
      on error
        set end of windowTitles to (i as text) & ". Chrome window"
      end try
    end repeat
  end tell

  set chosenIndex to 1
  if (count of windowTitles) > 1 then
    set picked to choose from list windowTitles with prompt "Choose the Chrome window/profile where Credential Vault should be installed. If titles are unclear, close other Chrome windows and rerun:" without multiple selections allowed
    if picked is false then return false
    set AppleScript's text item delimiters to ". "
    set chosenIndex to (text item 1 of (item 1 of picked)) as integer
    set AppleScript's text item delimiters to ""
  end if

  tell application "Google Chrome"
    set targetWindow to window chosenIndex
    set index of targetWindow to 1
    set URL of active tab of targetWindow to "chrome://extensions"
    activate
  end tell
  delay 3
  if setupMode is "update" then return true

  tell application "System Events"
    tell process "Google Chrome"
      set frontmost to true
      set devControl to my findNamedElement(window 1, "Developer mode")
      if devControl is missing value then error "Could not locate the Developer mode control. Complete setup manually in the open Chrome window."
      try
        set isEnabled to value of devControl
      on error
        set isEnabled to 0
      end try
      if isEnabled is not 1 then click devControl
      delay 1
      set loadControl to my findNamedElement(window 1, "Load unpacked")
      if loadControl is missing value then error "Could not locate Load unpacked. Complete setup manually in the open Chrome window."
      click loadControl
      delay 2
      keystroke "g" using {command down, shift down}
      delay 0.5
      keystroke extensionPath
      key code 36
      delay 1
      set folderButton to my findNamedElement(window 1, "Open")
      if folderButton is missing value then set folderButton to my findNamedElement(window 1, "Select")
      if folderButton is missing value then error "The folder picker is open. Select the Extension folder and click Open to finish."
      click folderButton
    end tell
  end tell
  delay 2
  return true
end run

on findNamedElement(container, wantedName)
  try
    set elements to UI elements of container
  on error
    return missing value
  end try
  repeat with elementRef in elements
    try
      if (name of elementRef as text) contains wantedName then return elementRef
    end try
    set nestedResult to my findNamedElement(elementRef, wantedName)
    if nestedResult is not missing value then return nestedResult
  end repeat
  return missing value
end findNamedElement
