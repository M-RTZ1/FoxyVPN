param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Target
)

Add-Type -AssemblyName System.Drawing

$image = [System.Drawing.Image]::FromFile($Source)
$side = [Math]::Min($image.Width, $image.Height)
$cropRect = New-Object System.Drawing.Rectangle `
    ([int](($image.Width - $side) / 2), [int](($image.Height - $side) / 2), $side, $side)

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$pngs = @()

foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap ($size, $size)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $gfx.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gfx.DrawImage($image, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)), $cropRect, [System.Drawing.GraphicsUnit]::Pixel)
    $gfx.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $pngs += , $ms.ToArray()
    $ms.Dispose()
}
$image.Dispose()

$offset = 6 + (16 * $sizes.Count)
$msOut = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($msOut)
$bw.Write([UInt16]0)      # reserved
$bw.Write([UInt16]1)      # type: icon
$bw.Write([UInt16]$sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $size = $sizes[$i]
    $data = $pngs[$i]
    $bw.Write([Byte]$(if ($size -ge 256) { 0 } else { $size }))
    $bw.Write([Byte]$(if ($size -ge 256) { 0 } else { $size }))
    $bw.Write([Byte]0)    # colors
    $bw.Write([Byte]0)    # reserved
    $bw.Write([UInt16]1)  # planes
    $bw.Write([UInt16]32) # bit count
    $bw.Write([UInt32]$data.Length)
    $bw.Write([UInt32]$offset)
    $offset += $data.Length
}
foreach ($data in $pngs) { $bw.Write($data) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($Target, $msOut.ToArray())
$bw.Dispose()
$msOut.Dispose()

Write-Output "wrote $Target ($((Get-Item $Target).Length) bytes)"
