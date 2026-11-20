#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
SetWorkingDir(A_ScriptDir)
;@Ahk2Exe-SetMainIcon tree.ico
;@Ahk2Exe-AddResource *10 deltarune-tree.gif, TREEGIF
;@Ahk2Exe-AddResource *10 man-ogg.mp3, MANBGM
;@Ahk2Exe-AddResource *10 snd_text.wav, TEXTSND
; Force Per-Monitor DPI Awareness so screen size, GUI, and SetCursorPos use identical physical pixels
try DllCall("SetProcessDpiAwarenessContext", "Ptr", -4, "Ptr")
CoordMode("Mouse", "Screen")
AssetDir    := A_AppData "\man"
if !DirExist(AssetDir)
    DirCreate(AssetDir)

TreeGifFile := A_IsCompiled ? (AssetDir "\deltarune-tree.gif") : (A_ScriptDir "\deltarune-tree.gif")
AudioFile   := A_IsCompiled ? (AssetDir "\man-ogg.mp3")        : (A_ScriptDir "\man-ogg.mp3")
TextSndFile := A_IsCompiled ? (AssetDir "\snd_text.wav")       : (A_ScriptDir "\snd_text.wav")

; Extract from compiled EXE resources (or fall back to local folder when running uncompiled .ahk)
if (A_IsCompiled) {
    ExtractResource("TREEGIF", TreeGifFile)
    ExtractResource("MANBGM", AudioFile)
    ExtractResource("TEXTSND", TextSndFile)
} else {
    TreeGifFile := A_IsCompiled ? (AssetDir "\deltarune-tree.gif") : (A_ScriptDir "\deltarune-tree.gif")
    AudioFile   := A_IsCompiled ? (AssetDir "\man-ogg.mp3")        : (A_ScriptDir "\man-ogg.mp3")
    TextSndFile := A_IsCompiled ? (AssetDir "\snd_text.wav")       : (A_ScriptDir "\snd_text.wav")
}
EnsureExtractedAssets() {
    global AssetDir, TreeGifFile, AudioFile, TextSndFile
    if (!A_IsCompiled)
        return
    if !DirExist(AssetDir)
        DirCreate(AssetDir)
    if !FileExist(TreeGifFile)
        ExtractResource("TREEGIF", TreeGifFile)
    if !FileExist(AudioFile)
        ExtractResource("MANBGM", AudioFile)
    if !FileExist(TextSndFile)
        ExtractResource("TEXTSND", TextSndFile)
}

ExtractResource(ResName, OutPath) {
    hMod := DllCall("GetModuleHandleW", "Ptr", 0, "Ptr")
    hRes := DllCall("FindResourceW", "Ptr", hMod, "Str", ResName, "Ptr", 10, "Ptr")
    if !hRes
        return false
    resSize := DllCall("SizeofResource", "Ptr", hMod, "Ptr", hRes, "UInt")
    hData   := DllCall("LoadResource", "Ptr", hMod, "Ptr", hRes, "Ptr")
    pData   := DllCall("LockResource", "Ptr", hData, "Ptr")
    if (!pData || !resSize)
        return false
    f := FileOpen(OutPath, "w")
    f.RawWrite(pData + 0, resSize)
    f.Close()
    return true
}
; ================= CONFIGURATION =================

; Mouse Shake Tuning:
ShakeThreshold  := 8      ; Number of rapid horizontal reversals needed
ShakeTimeWindow := 900    ; Time window in milliseconds (0.9s)
MinMoveDistance := 25     ; Minimum pixels per swing to count
; =================================================

global IsInEggRoom := false
global LastX := 0, LastY := 0
global LastDirX := 0
global ShakeTimestamps := []

global CurrentEgg := ""
global EggDoc := ""
global EggScale := 1
global EggOffsetX := 0
global PrevScreenX := 0
global PrevScreenY := 0

global DialogueActive := false
global DialogueStep := 0
global ManGone := false
global ChoiceActive := false
global SelectedChoice := 0 ; 0 = Yes, 1 = No
global WmpPlayer := ""

; Typewriter state
global FullDialogueText := ""
global TypedCharCount := 0
global IsTyping := false

MouseGetPos(&LastX, &LastY)
SetTimer(MainLoop, 10)

MainLoop() {
    global IsInEggRoom
    if (!IsInEggRoom) {
        CheckMouseShake()
    } else {
        ClampCursorToRoom()
    }
}

CheckMouseShake() {
    global LastX, LastY, LastDirX, ShakeTimestamps, ShakeThreshold, ShakeTimeWindow, MinMoveDistance

    MouseGetPos(&CurrX, &CurrY)
    DeltaX := CurrX - LastX

    if (Abs(DeltaX) >= MinMoveDistance) {
        CurrDirX := (DeltaX > 0) ? 1 : -1

        if (LastDirX != 0 && CurrDirX != LastDirX) {
            Now := A_TickCount
            ShakeTimestamps.Push(Now)

            while (ShakeTimestamps.Length > 0 && (Now - ShakeTimestamps[1] > ShakeTimeWindow)) {
                ShakeTimestamps.RemoveAt(1)
            }

            if (ShakeTimestamps.Length >= ShakeThreshold) {
                ShakeTimestamps := []
                global CurrentEgg := ShowEggRoom()
            }
        }
        LastDirX := CurrDirX
        LastX := CurrX
        LastY := CurrY
    }
}

PlayLoopingMusic(FilePath) {
    global WmpPlayer
    if !FileExist(FilePath)
        return
    StopLoopingMusic()
    WmpPlayer := ComObject("WMPlayer.OCX")
    WmpPlayer.settings.setMode("loop", true)
    WmpPlayer.settings.volume := 100
    WmpPlayer.URL := FilePath
    WmpPlayer.controls.play()
}

StopLoopingMusic() {
    global WmpPlayer
    if IsObject(WmpPlayer) {
        try WmpPlayer.controls.stop()
        try WmpPlayer.close()
        WmpPlayer := ""
    }
}

PlayTextBlip() {
    global TextSndFile
    if FileExist(TextSndFile) {
        ; SND_ASYNC (0x1) | SND_FILENAME (0x20000) | SND_NODEFAULT (0x2)
        DllCall("winmm\PlaySoundW", "Str", TextSndFile, "Ptr", 0, "UInt", 0x20003)
    }
}

StartDialogue(Text, ShowChoices := false) {
    global FullDialogueText, TypedCharCount, IsTyping, ChoiceActive, SelectedChoice, EggDoc
    FullDialogueText := Text
    TypedCharCount := 0
    IsTyping := true
    ChoiceActive := ShowChoices
    SelectedChoice := 0

    if IsObject(EggDoc) {
        EggDoc.getElementById("dlgBox").style.display := "block"
        EggDoc.getElementById("dlgText").innerText := ""
        EggDoc.getElementById("dlgChoices").style.display := "none"
        UpdateChoiceUI()
    }
    SetTimer(TypewriterTick, 25)
}

TypewriterTick() {
    global FullDialogueText, TypedCharCount, IsTyping, ChoiceActive, EggDoc, IsInEggRoom

    if (!IsInEggRoom || !IsObject(EggDoc)) {
        IsTyping := false
        SetTimer(TypewriterTick, 0)
        return
    }

    TypedCharCount += 1
    totalLen := StrLen(FullDialogueText)

    if (TypedCharCount <= totalLen) {
        ch := SubStr(FullDialogueText, TypedCharCount, 1)
        EggDoc.getElementById("dlgText").innerText := SubStr(FullDialogueText, 1, TypedCharCount)

        if (ch != " " && ch != "`n" && ch != "`r") {
            PlayTextBlip()
        }
    }

    if (TypedCharCount >= totalLen) {
        IsTyping := false
        SetTimer(TypewriterTick, 0)
        if (ChoiceActive && IsObject(EggDoc)) {
            EggDoc.getElementById("dlgChoices").style.display := "block"
        }
    }
}

FinishDialogueInstant() {
    global FullDialogueText, TypedCharCount, IsTyping, ChoiceActive, EggDoc
    SetTimer(TypewriterTick, 0)
    IsTyping := false
    TypedCharCount := StrLen(FullDialogueText)
    if IsObject(EggDoc) {
        EggDoc.getElementById("dlgText").innerText := FullDialogueText
        if (ChoiceActive) {
            EggDoc.getElementById("dlgChoices").style.display := "block"
        }
    }
}

UpdateChoiceUI() {
    global SelectedChoice, EggDoc
    if !IsObject(EggDoc)
        return
    yesEl := EggDoc.getElementById("optYes")
    noEl  := EggDoc.getElementById("optNo")
    yesEl.style.color := (SelectedChoice = 0) ? "#FFFF00" : "#FFFFFF"
    noEl.style.color  := (SelectedChoice = 1) ? "#FFFF00" : "#FFFFFF"
}

ShowEggRoom() {
    EnsureExtractedAssets()
    global IsInEggRoom, EggDoc, EggScale, EggOffsetX, PrevScreenX, PrevScreenY
    global DialogueActive, DialogueStep, ManGone, ChoiceActive, SelectedChoice, IsTyping, TreeGifFile, AudioFile

    DialogueActive := false
    DialogueStep := 0
    ManGone := false
    ChoiceActive := false
    SelectedChoice := 0
    IsTyping := false

    PlayLoopingMusic(AudioFile)

    w := DllCall("GetSystemMetrics", "Int", 0, "Int")
    h := DllCall("GetSystemMetrics", "Int", 1, "Int")

    ; Maintain Deltarune's 4:3 aspect ratio centered on any monitor
    EggScale := h / 480
    EggOffsetX := (w - (640 * EggScale)) / 2

    EggGui := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale")
    EggGui.BackColor := "000000"

    wb := EggGui.AddActiveX("x0 y0 w" w " h" h, "Shell.Explorer")
    wb.Value.Silent := true
    wb.Value.Navigate("about:blank")
    while wb.Value.ReadyState != 4
        Sleep(10)

    gifUrl := "data:image/gif;base64," FileToBase64(TreeGifFile)

    ; Scaled coordinates for the 640x480 room
    topX := Round(EggOffsetX + 160 * EggScale), topY := Round(120 * EggScale), topW := Round(320 * EggScale), topH := Round(160 * EggScale)
    botX := Round(EggOffsetX + 280 * EggScale), botY := Round(280 * EggScale), botW := Round(80 * EggScale),  botH := Round(200 * EggScale)

    ; Tree position: centered horizontally, base planted in the top clearing
    treeW := Round(110 * EggScale)
    treeH := Round(130 * EggScale)
    treeX := Round(EggOffsetX + (320 * EggScale) - (treeW / 2))
    treeY := Round(125 * EggScale)

    ; Deltarune bottom dialogue box scaled to 640x480 space
    boxX := Round(EggOffsetX + 40 * EggScale)
    boxY := Round(320 * EggScale)
    boxW := Round(560 * EggScale)
    boxH := Round(140 * EggScale)
    borderPx := Max(2, Round(4 * EggScale))
    fontPx   := Round(18 * EggScale)
    padPx    := Round(18 * EggScale)

    html := '<!DOCTYPE html><html><head><meta http-equiv="X-UA-Compatible" content="IE=edge"></head>'
          . '<body oncontextmenu="return false;" style="margin:0;padding:0;overflow:hidden;background:#000000;user-select:none;">'
          . '<div style="position:absolute;left:' topX 'px;top:' topY 'px;width:' topW 'px;height:' topH 'px;background:#593A57;"></div>'
          . '<div style="position:absolute;left:' botX 'px;top:' botY 'px;width:' botW 'px;height:' botH 'px;background:#593A57;"></div>'
          . '<img src="' gifUrl '" style="position:absolute;z-index:10;left:' treeX 'px;top:' treeY 'px;width:' treeW 'px;height:' treeH 'px;image-rendering:pixelated;pointer-events:none;">'
          . '<div id="dlgBox" style="display:none;position:absolute;z-index:20;left:' boxX 'px;top:' boxY 'px;width:' boxW 'px;height:' boxH 'px;'
          . 'background:#000000;border:' borderPx 'px solid #FFFFFF;box-sizing:border-box;padding:' padPx 'px;'
          . 'color:#FFFFFF;font-family:Consolas,monospace;font-size:' fontPx 'px;font-weight:bold;line-height:1.4;pointer-events:none;">'
          . '<div id="dlgText"></div>'
          . '<div id="dlgChoices" style="display:none;margin-top:' Round(14 * EggScale) 'px;padding-left:' Round(24 * EggScale) 'px;pointer-events:auto;">'
          . '<span id="optYes" style="color:#FFFF00;margin-right:' Round(80 * EggScale) 'px;cursor:pointer;">Yes</span>'
          . '<span id="optNo" style="color:#FFFFFF;cursor:pointer;">No</span>'
          . '</div></div>'
          . '</body></html>'

    wb.Value.Document.Write(html)
    wb.Value.Document.Close()
    EggDoc := wb.Value.Document

    EggGui.Show("x0 y0 w" w " h" h)

    ; Snap cursor to bottom entrance in physical screen coordinates
    StartX := Round(EggOffsetX + (320 * EggScale))
    StartY := Round(435 * EggScale)
    DllCall("SetCursorPos", "Int", StartX, "Int", StartY)
    PrevScreenX := StartX
    PrevScreenY := StartY
    IsInEggRoom := true

    return EggGui
}

ClampCursorToRoom() {
    global EggScale, EggOffsetX, PrevScreenX, PrevScreenY, DialogueActive, ChoiceActive, IsTyping, SelectedChoice

    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    mx := NumGet(pt, 0, "Int")
    my := NumGet(pt, 4, "Int")

    if (DialogueActive) {
        if (ChoiceActive && !IsTyping) {
        pt := Buffer(8, 0)
        DllCall("GetCursorPos", "Ptr", pt)
        rx := (NumGet(pt, 0, "Int") - EggOffsetX) / EggScale
        ry := NumGet(pt, 4, "Int") / EggScale
            if (ry >= 370 && ry <= 415) {
                newChoice := (rx >= 75 && rx <= 140) ? 0 : (rx >= 185 && rx <= 245) ? 1 : SelectedChoice
                if (newChoice != SelectedChoice) {
                    SelectedChoice := newChoice
                    UpdateChoiceUI()
                }
            }
            return
        }
        if (mx != PrevScreenX || my != PrevScreenY)
            DllCall("SetCursorPos", "Int", PrevScreenX, "Int", PrevScreenY)
        return
    }

    rx := (mx - EggOffsetX) / EggScale
    ry := my / EggScale

    if (ry >= 479 && rx >= 280 && rx <= 360) {
        ExitEggRoom()
        return
    }

    prevRx := (PrevScreenX - EggOffsetX) / EggScale
    prevRy := PrevScreenY / EggScale

    inTop := (rx >= 164 && rx <= 476 && ry >= 124 && ry <= 280)
    inBot := (rx >= 284 && rx <= 356 && ry >= 280 && ry <= 480)

    if (inTop || inBot) {
        clampedX := rx
        clampedY := ry
    } else if (prevRy > 282) {
        clampedX := Max(284, Min(356, rx))
        clampedY := Max(124, Min(480, ry))
    } else {
        clampedX := Max(164, Min(476, rx))
        clampedY := Max(124, Min(280, ry))
    }

    targetScreenX := Round(EggOffsetX + (clampedX * EggScale))
    targetScreenY := Round(clampedY * EggScale)

    if (targetScreenX != mx || targetScreenY != my) {
        DllCall("SetCursorPos", "Int", targetScreenX, "Int", targetScreenY)
    }
    PrevScreenX := targetScreenX
    PrevScreenY := targetScreenY
}

#HotIf IsInEggRoom
Left::
a::
Right::
d:: {
    global ChoiceActive, IsTyping, SelectedChoice
    if (ChoiceActive && !IsTyping) {
        SelectedChoice := 1 - SelectedChoice
        UpdateChoiceUI()
    }
}

LButton::
z::
Enter:: {
    global DialogueActive, DialogueStep, ManGone, ChoiceActive, SelectedChoice
    global IsTyping, EggDoc, EggScale, EggOffsetX

    if (!IsObject(EggDoc))
        return

    if (DialogueActive && IsTyping) {
        FinishDialogueInstant()
        return
    }

    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", CurrentEgg.Hwnd, "Ptr", pt)
    CurrentEgg.GetClientPos(, , &clientW, &clientH)
    scale   := clientH / 480
    offsetX := (clientW - (640 * scale)) / 2
    rx := (NumGet(pt, 0, "Int") - offsetX) / scale
    ry := NumGet(pt, 4, "Int") / scale
    dlg := EggDoc.getElementById("dlgBox")

    if (!DialogueActive) {
        ; Behind the leaves (covers the entire red canopy down to the base of the leaves)
        if (rx >= 260 && rx <= 380 && ry >= 90 && ry <= 190) {
            DialogueActive := true
            DialogueStep := 1
            if (ManGone) {
                StartDialogue("(Well, there is not a man here.)")
            } else {
                StartDialogue("(Well, there is a man here.)")
            }
            return
        }
        ; Front / trunk of the tree (only the roots/trunk at the very bottom)
        if (rx >= 285 && rx <= 355 && ry >= 226 && ry <= 260) {
            DialogueActive := true
            DialogueStep := 99
            if (ManGone) {
                StartDialogue("(It is a tree.)")
            } else {
                StartDialogue("(He is behind the tree.)")
            }
            return
        }
        return
    }

    if (ChoiceActive) {
        ChoiceActive := false
        ManGone := true
        EggDoc.getElementById("dlgChoices").style.display := "none"
        if (SelectedChoice = 0) {
            StartDialogue("(You received an Egg.)")
        } else {
            StartDialogue("(Then he needn't be here.)")
        }
        DialogueStep := 99
        return
    }

    if (DialogueStep = 1 && !ManGone) {
        DialogueStep := 2
        StartDialogue("(He offered you something.)", true)
        return
    }

    dlg.style.display := "none"
    DialogueActive := false
}

Esc::ExitEggRoom()
#HotIf
SetSystemCursor(CursorFile) {
    hCursor := DllCall("LoadCursorFromFile", "Str", CursorFile, "Ptr")
    if (hCursor) {
        hCopy := DllCall("CopyIcon", "Ptr", hCursor, "Ptr")
        DllCall("SetSystemCursor", "Ptr", hCopy, "UInt", 32512)
    }
}
RestoreSystemCursor() {
    DllCall("SystemParametersInfo", "UInt", 0x0057, "UInt", 0, "Ptr", 0, "UInt", 0)
}
ExitEggRoom() {
    global IsInEggRoom, CurrentEgg, EggDoc, IsTyping
    SetTimer(TypewriterTick, 0)
    IsTyping := false
    StopLoopingMusic()
    RestoreSystemCursor()
    if IsObject(CurrentEgg) {
        CurrentEgg.Destroy()
        CurrentEgg := ""
    }
    EggDoc := ""
    IsInEggRoom := false
    MouseGetPos(&LastX, &LastY)
}
FileToBase64(FilePath) {
    if !FileExist(FilePath)
        return ""
    buf := FileRead(FilePath, "RAW")
    ; CRYPT_STRING_BASE64 (0x1) | CRYPT_STRING_NOCRLF (0x40000000)
    DllCall("Crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", 0, "UInt*", &outLen := 0)
    outBuf := Buffer(outLen * 2)
    DllCall("Crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", outBuf, "UInt*", &outLen)
    return StrGet(outBuf, "UTF-16")
}
