$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = $PSScriptRoot
$sourcePath = Join-Path $root '电工猴的此思妙想工作台.png'
$iconPath = Join-Path $root '电工猴的此思妙想工作台-高清.ico'
$sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Icon source image not found: $sourcePath"
}

$source = [System.Drawing.Image]::FromFile($sourcePath)
$frames = New-Object 'System.Collections.Generic.List[object]'
try {
    foreach ($size in $sizes) {
        $bitmap = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.DrawImage($source, 0, 0, $size, $size)

            $xor = [byte[]]::new($size * $size * 4)
            $andStride = [int]([Math]::Ceiling($size / 32.0) * 4)
            $and = [byte[]]::new($andStride * $size)
            for ($y = 0; $y -lt $size; $y++) {
                $bottomUpY = $size - 1 - $y
                for ($x = 0; $x -lt $size; $x++) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    $pixelOffset = (($bottomUpY * $size) + $x) * 4
                    $xor[$pixelOffset] = $pixel.B
                    $xor[$pixelOffset + 1] = $pixel.G
                    $xor[$pixelOffset + 2] = $pixel.R
                    $xor[$pixelOffset + 3] = $pixel.A

                    if ($pixel.A -lt 128) {
                        $maskOffset = ($bottomUpY * $andStride) + [int][Math]::Floor($x / 8)
                        $and[$maskOffset] = $and[$maskOffset] -bor [byte](0x80 -shr ($x % 8))
                    }
                }
            }

            $frameStream = New-Object System.IO.MemoryStream
            $frameWriter = New-Object System.IO.BinaryWriter($frameStream)
            try {
                $frameWriter.Write([UInt32]40)
                $frameWriter.Write([Int32]$size)
                $frameWriter.Write([Int32]($size * 2))
                $frameWriter.Write([UInt16]1)
                $frameWriter.Write([UInt16]32)
                $frameWriter.Write([UInt32]0)
                $frameWriter.Write([UInt32]($xor.Length + $and.Length))
                $frameWriter.Write([Int32]0)
                $frameWriter.Write([Int32]0)
                $frameWriter.Write([UInt32]0)
                $frameWriter.Write([UInt32]0)
                $frameWriter.Write($xor)
                $frameWriter.Write($and)
                $frames.Add([pscustomobject]@{ Size = $size; Bytes = $frameStream.ToArray() })
            }
            finally {
                $frameWriter.Dispose()
            }
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
}
finally {
    $source.Dispose()
}

$stream = [System.IO.File]::Open($iconPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
$writer = New-Object System.IO.BinaryWriter($stream)
try {
    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]$frames.Count)

    $offset = 6 + (16 * $frames.Count)
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -eq 256) { [byte]0 } else { [byte]$frame.Size }
        $writer.Write($dimension)
        $writer.Write($dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$frame.Bytes.Length)
        $writer.Write([UInt32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) {
        $writer.Write($frame.Bytes)
    }
}
finally {
    $writer.Dispose()
}

Write-Output "Created $iconPath with uncompressed sizes: $($sizes -join ', ')"

