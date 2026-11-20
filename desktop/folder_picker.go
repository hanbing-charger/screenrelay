package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"os/exec"
	"runtime"
	"strings"
	"unicode/utf16"
)

const macFolderPicker = `
on run
	set currentFolder to system attribute "SCREENRELAY_PICKER_FOLDER"
	set startFolder to path to home folder
	if currentFolder is not "" then
		try
			set startFolder to (POSIX file currentFolder) as alias
		end try
	end if
	try
		set selectedFolder to choose folder with prompt "选择接收文件夹" default location startFolder
		return POSIX path of selectedFolder
	on error messageText number messageNumber
		if messageNumber is -128 then return ""
		error messageText number messageNumber
	end try
end run
`

const windowsFolderPicker = `
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = '选择接收文件夹'
$dialog.ShowNewFolderButton = $true
try {
	$currentFolder = $env:SCREENRELAY_PICKER_FOLDER
	if ($currentFolder -and [System.IO.Directory]::Exists($currentFolder)) {
		$dialog.SelectedPath = $currentFolder
	}
	if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		[Console]::Write($dialog.SelectedPath)
	}
} finally {
	$dialog.Dispose()
}
`

func pickReceiveFolder(ctx context.Context, current string) (string, error) {
	var command *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		command = exec.CommandContext(ctx, "/usr/bin/osascript", "-e", macFolderPicker)
	case "windows":
		// EncodedCommand uses UTF-16LE, including when the prompt is localized.
		chars := utf16.Encode([]rune(windowsFolderPicker))
		script := make([]byte, len(chars)*2)
		for i, char := range chars {
			binary.LittleEndian.PutUint16(script[i*2:], char)
		}
		command = exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-STA",
			"-EncodedCommand", base64.StdEncoding.EncodeToString(script))
	default:
		return "", errors.New("当前系统没有可用的文件夹选择器，请手动输入接收目录。")
	}
	command.Env = append(command.Environ(), "SCREENRELAY_PICKER_FOLDER="+current)
	output, err := command.Output()
	if err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return "", fmt.Errorf("无法打开系统文件夹选择器（%w）", err)
	}
	// osascript adds one line ending. A selected folder's whitespace is part of its path.
	return strings.TrimSuffix(string(output), "\n"), nil
}
