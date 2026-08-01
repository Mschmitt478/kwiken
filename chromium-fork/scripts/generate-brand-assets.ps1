param(
  [Parameter(Mandatory = $true)]
  [string]$SourceRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath {
  param(
    [System.Drawing.RectangleF]$Rectangle,
    [float]$Radius
  )

  $diameter = $Radius * 2
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
  $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
  $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-IconPngBytes {
  param([int]$Size)

  $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $graphics.Clear([System.Drawing.Color]::Transparent)

  $inset = [Math]::Max(1, [Math]::Round($Size * 0.045))
  $rectangle = [System.Drawing.RectangleF]::new($inset, $inset, $Size - ($inset * 2), $Size - ($inset * 2))
  $path = New-RoundedRectanglePath -Rectangle $rectangle -Radius ($Size * 0.235)
  $startColor = [System.Drawing.Color]::FromArgb(255, 226, 255, 164)
  $endColor = [System.Drawing.Color]::FromArgb(255, 160, 220, 47)
  $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    $rectangle,
    $startColor,
    $endColor,
    [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
  )
  $graphics.FillPath($brush, $path)

  $fontSize = [Math]::Max(7, $Size * 0.54)
  $font = [System.Drawing.Font]::new("Segoe UI", $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 18, 24, 12))
  $format = [System.Drawing.StringFormat]::new()
  $format.Alignment = [System.Drawing.StringAlignment]::Center
  $format.LineAlignment = [System.Drawing.StringAlignment]::Center
  $textRectangle = [System.Drawing.RectangleF]::new(0, -($Size * 0.025), $Size, $Size)
  $graphics.DrawString("K", $font, $textBrush, $textRectangle, $format)

  $stream = [System.IO.MemoryStream]::new()
  $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  $bytes = $stream.ToArray()

  $stream.Dispose()
  $format.Dispose()
  $textBrush.Dispose()
  $font.Dispose()
  $brush.Dispose()
  $path.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
  return $bytes
}

function Write-Ico {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [object[]]$Images
  )

  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
  $writer = [System.IO.BinaryWriter]::new($stream)
  try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$Images.Count)

    $offset = 6 + (16 * $Images.Count)
    foreach ($image in $Images) {
      $size = [int]$image[0]
      $bytes = [byte[]]$image[1]
      $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
      $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
      $writer.Write([byte]0)
      $writer.Write([byte]0)
      $writer.Write([uint16]1)
      $writer.Write([uint16]32)
      $writer.Write([uint32]$bytes.Length)
      $writer.Write([uint32]$offset)
      $offset += $bytes.Length
    }

    foreach ($image in $Images) {
      $writer.Write([byte[]]$image[1])
    }
  } finally {
    $writer.Dispose()
    $stream.Dispose()
  }
}

$themeRoot = Join-Path $SourceRoot "chrome\app\theme\chromium"
$windowsThemeRoot = Join-Path $themeRoot "win"
$tileRoot = Join-Path $windowsThemeRoot "tiles"
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = @()

foreach ($size in $sizes) {
  $bytes = New-IconPngBytes -Size $size
  $images += ,@($size, $bytes)
  $pngPath = Join-Path $themeRoot "product_logo_$size.png"
  if (Test-Path $pngPath) {
    [System.IO.File]::WriteAllBytes($pngPath, $bytes)
  }
}

Write-Ico -Path (Join-Path $windowsThemeRoot "chromium.ico") -Images $images
Write-Ico -Path (Join-Path $windowsThemeRoot "app_list.ico") -Images $images
[System.IO.File]::WriteAllBytes((Join-Path $tileRoot "Logo.png"), (New-IconPngBytes -Size 600))
[System.IO.File]::WriteAllBytes((Join-Path $tileRoot "SmallLogo.png"), (New-IconPngBytes -Size 176))

Write-Output "Generated Kwiken product assets in $themeRoot."
