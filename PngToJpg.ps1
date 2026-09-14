param(
    [string[]]$InputFiles,
    [switch]$OpenEnhancement,
    [switch]$SmokeTest,
    [switch]$SmokeTestWebUi,
    [switch]$SmokeTestClarityConversion,
    [switch]$SmokeTestConversion,
    [switch]$SmokeTestCustomNaming,
    [switch]$SmokeTestPreview,
    [string]$SmokeTestScreenshotPath,
    [string]$SmokeTestEnhancementScreenshotPath,
    [string]$SmokeTestOrganizerScreenshotPath,
    [string]$SmokeTestSpreadsheetPageScreenshotPath,
    [string]$SmokeTestChangelogScreenshotPath,
    [string]$SmokeTestIslandScreenshotPath,
    [ValidateSet('', 'Monitoring', 'Processing', 'Complete')]
    [string]$SmokeTestIslandGlowMode = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing.Common

if (-not ('ListViewScroller' -as [type])) {
    $winFormsTypeReferences = @(
        [System.Windows.Forms.Control].Assembly.Location,
        [System.Windows.Forms.Message].Assembly.Location,
        [System.ComponentModel.Component].Assembly.Location,
        [System.Threading.Interlocked].Assembly.Location,
        [System.Drawing.Graphics].Assembly.Location,
        [System.Drawing.Rectangle].Assembly.Location,
        (Join-Path ([System.IO.Path]::GetDirectoryName([System.Drawing.Graphics].Assembly.Location)) 'System.Private.Windows.GdiPlus.dll'),
        (Join-Path ([System.IO.Path]::GetDirectoryName([System.Drawing.Graphics].Assembly.Location)) 'System.Private.Windows.Core.dll'),
        (Join-Path ([System.IO.Path]::GetDirectoryName([System.Drawing.Graphics].Assembly.Location)) 'System.Threading.dll'),
        (Join-Path ([System.IO.Path]::GetDirectoryName([System.Drawing.Graphics].Assembly.Location)) 'System.Threading.Thread.dll'),
        (Join-Path ([System.IO.Path]::GetDirectoryName([System.Drawing.Graphics].Assembly.Location)) 'System.Threading.Timer.dll')
    )
    $winFormsTypeDefinition = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class ListViewScroller
{
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int message, IntPtr wParam, IntPtr lParam);

    public const int WM_HSCROLL = 0x0114;
    public const int WM_VSCROLL = 0x0115;
    public const int LVM_SCROLL = 0x1014;
    public const int SB_PAGEUP = 2;
    public const int SB_PAGEDOWN = 3;
    public const int SB_PAGELEFT = 2;
    public const int SB_PAGERIGHT = 3;
}

public static class SpreadsheetWindowMover
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRectangle
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowPlacement
    {
        public int length;
        public int flags;
        public int showCmd;
        public Point minPosition;
        public Point maxPosition;
        public NativeRectangle normalPosition;
    }

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr window);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(IntPtr window, ref WindowPlacement placement);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    public static IntPtr FindVisibleWindow(string titleFragment)
    {
        IntPtr[] matches = FindVisibleWindows(titleFragment);
        return matches.Length == 0 ? IntPtr.Zero : matches[0];
    }

    public static IntPtr[] FindVisibleWindows(string titleFragment)
    {
        if (String.IsNullOrWhiteSpace(titleFragment)) return new IntPtr[0];
        System.Collections.ArrayList matches = new System.Collections.ArrayList();
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window)) return true;
            int length = GetWindowTextLength(window);
            if (length <= 0) return true;
            System.Text.StringBuilder title = new System.Text.StringBuilder(length + 1);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString().IndexOf(titleFragment, StringComparison.CurrentCultureIgnoreCase) < 0) return true;
            matches.Add(window);
            return true;
        }, IntPtr.Zero);
        return (IntPtr[])matches.ToArray(typeof(IntPtr));
    }

    public static bool MoveToWorkingArea(IntPtr window, Rectangle workingArea)
    {
        if (window == IntPtr.Zero || workingArea.Width <= 0 || workingArea.Height <= 0) return false;
        WindowPlacement placement = new WindowPlacement();
        placement.length = Marshal.SizeOf(typeof(WindowPlacement));
        bool wasMaximized = GetWindowPlacement(window, ref placement) && placement.showCmd == 3;
        if (wasMaximized || placement.showCmd == 2) ShowWindowAsync(window, 9);

        int width = placement.normalPosition.right - placement.normalPosition.left;
        int height = placement.normalPosition.bottom - placement.normalPosition.top;
        if (width < 400 || width > workingArea.Width) width = Math.Max(400, Math.Min(workingArea.Width, (int)(workingArea.Width * 0.85)));
        if (height < 300 || height > workingArea.Height) height = Math.Max(300, Math.Min(workingArea.Height, (int)(workingArea.Height * 0.85)));
        int x = workingArea.Left + Math.Max(0, (workingArea.Width - width) / 2);
        int y = workingArea.Top + Math.Max(0, (workingArea.Height - height) / 2);
        bool moved = SetWindowPos(window, IntPtr.Zero, x, y, width, height, 0x0004 | 0x0010);
        if (moved && wasMaximized) ShowWindowAsync(window, 3);
        return moved;
    }
}

public class VerticalWheelListView : ListView
{
    private const int WM_MOUSEWHEEL = 0x020A;

    public event MouseEventHandler VerticalMouseWheel;

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_MOUSEWHEEL && VerticalMouseWheel != null)
        {
            int delta = unchecked((short)(((long)message.WParam >> 16) & 0xffff));
            VerticalMouseWheel(this, new MouseEventArgs(MouseButtons.None, 0, 0, 0, delta));
            return;
        }
        base.WndProc(ref message);
    }
}

public static class ImageHeaderReader
{
    public static bool TryGetDimensions(string path, out int width, out int height)
    {
        width = 0;
        height = 0;
        try
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (BinaryReader reader = new BinaryReader(stream))
            {
                byte[] signature = reader.ReadBytes(12);
                if (signature.Length < 12) return false;
                stream.Position = 0;

                if (signature[0] == 0x89 && signature[1] == 0x50 && signature[2] == 0x4E && signature[3] == 0x47)
                {
                    stream.Position = 16;
                    width = ReadInt32BigEndian(reader);
                    height = ReadInt32BigEndian(reader);
                    return width > 0 && height > 0;
                }

                if (signature[0] == 0xFF && signature[1] == 0xD8)
                {
                    stream.Position = 2;
                    while (stream.Position < stream.Length)
                    {
                        int prefix;
                        do { prefix = reader.ReadByte(); } while (prefix != 0xFF && stream.Position < stream.Length);
                        int marker;
                        do { marker = reader.ReadByte(); } while (marker == 0xFF && stream.Position < stream.Length);
                        if (marker == 0xD9 || marker == 0xDA) break;
                        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
                        int length = ReadUInt16BigEndian(reader);
                        if (length < 2 || stream.Position + length - 2 > stream.Length) return false;
                        if ((marker >= 0xC0 && marker <= 0xC3) || (marker >= 0xC5 && marker <= 0xC7) ||
                            (marker >= 0xC9 && marker <= 0xCB) || (marker >= 0xCD && marker <= 0xCF))
                        {
                            reader.ReadByte();
                            height = ReadUInt16BigEndian(reader);
                            width = ReadUInt16BigEndian(reader);
                            return width > 0 && height > 0;
                        }
                        stream.Position += length - 2;
                    }
                    return false;
                }

                if (signature[0] == (byte)'R' && signature[1] == (byte)'I' && signature[2] == (byte)'F' && signature[3] == (byte)'F' &&
                    signature[8] == (byte)'W' && signature[9] == (byte)'E' && signature[10] == (byte)'B' && signature[11] == (byte)'P')
                {
                    stream.Position = 12;
                    while (stream.Position + 8 <= stream.Length)
                    {
                        string chunk = new string(reader.ReadChars(4));
                        uint size = reader.ReadUInt32();
                        long dataStart = stream.Position;
                        if (chunk == "VP8X" && size >= 10)
                        {
                            byte[] data = reader.ReadBytes(10);
                            width = 1 + data[4] + (data[5] << 8) + (data[6] << 16);
                            height = 1 + data[7] + (data[8] << 8) + (data[9] << 16);
                            return width > 0 && height > 0;
                        }
                        if (chunk == "VP8L" && size >= 5)
                        {
                            byte[] data = reader.ReadBytes(5);
                            if (data[0] != 0x2F) return false;
                            width = 1 + data[1] + ((data[2] & 0x3F) << 8);
                            height = 1 + (data[2] >> 6) + (data[3] << 2) + ((data[4] & 0x0F) << 10);
                            return width > 0 && height > 0;
                        }
                        if (chunk == "VP8 " && size >= 10)
                        {
                            byte[] data = reader.ReadBytes(10);
                            if (data[3] != 0x9D || data[4] != 0x01 || data[5] != 0x2A) return false;
                            width = (data[6] | (data[7] << 8)) & 0x3FFF;
                            height = (data[8] | (data[9] << 8)) & 0x3FFF;
                            return width > 0 && height > 0;
                        }
                        stream.Position = dataStart + size + (size % 2);
                    }
                }
            }
        }
        catch { }
        return false;
    }

    private static int ReadInt32BigEndian(BinaryReader reader)
    {
        byte[] value = reader.ReadBytes(4);
        if (value.Length != 4) return 0;
        return (value[0] << 24) | (value[1] << 16) | (value[2] << 8) | value[3];
    }

    private static int ReadUInt16BigEndian(BinaryReader reader)
    {
        int high = reader.ReadByte();
        int low = reader.ReadByte();
        return (high << 8) | low;
    }
}

public static class ReferenceUiDrawing
{
    public static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
    {
        float diameter = Math.Max(2f, Math.Min(radius * 2f, Math.Min(bounds.Width, bounds.Height)));
        GraphicsPath path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

public class ReferenceUiForm : Form
{
    private const int WS_MINIMIZEBOX = 0x00020000;
    private const int WS_MAXIMIZEBOX = 0x00010000;
    private const int WS_SYSMENU = 0x00080000;
    private const int WM_NCHITTEST = 0x0084;
    private const int HTCLIENT = 1;
    private const int HTCAPTION = 2;
    private const int HTLEFT = 10;
    private const int HTRIGHT = 11;
    private const int HTTOP = 12;
    private const int HTTOPLEFT = 13;
    private const int HTTOPRIGHT = 14;
    private const int HTBOTTOM = 15;
    private const int HTBOTTOMLEFT = 16;
    private const int HTBOTTOMRIGHT = 17;

    public ReferenceUiForm()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.FromArgb(232, 238, 248);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.Style |= WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU;
            return parameters;
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        MaximizedBounds = Screen.FromHandle(Handle).WorkingArea;
    }

    protected override void WndProc(ref Message message)
    {
        base.WndProc(ref message);
        if (message.Msg != WM_NCHITTEST || WindowState != FormWindowState.Normal || (int)message.Result != HTCLIENT) return;

        Point point = PointToClient(Cursor.Position);
        int grip = 7;
        bool left = point.X < grip;
        bool right = point.X >= ClientSize.Width - grip;
        bool top = point.Y < grip;
        bool bottom = point.Y >= ClientSize.Height - grip;

        if (left && top) message.Result = (IntPtr)HTTOPLEFT;
        else if (right && top) message.Result = (IntPtr)HTTOPRIGHT;
        else if (left && bottom) message.Result = (IntPtr)HTBOTTOMLEFT;
        else if (right && bottom) message.Result = (IntPtr)HTBOTTOMRIGHT;
        else if (left) message.Result = (IntPtr)HTLEFT;
        else if (right) message.Result = (IntPtr)HTRIGHT;
        else if (top) message.Result = (IntPtr)HTTOP;
        else if (bottom) message.Result = (IntPtr)HTBOTTOM;
        else if (point.Y < 38) message.Result = (IntPtr)HTCAPTION;
    }

    protected override void OnDoubleClick(EventArgs e)
    {
        if (PointToClient(Cursor.Position).Y < 38)
        {
            WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
            return;
        }
        base.OnDoubleClick(e);
    }
}

public class ReferenceUiCard : Panel
{
    private int cornerRadius = 18;
    private Color outerColor = Color.FromArgb(232, 238, 248);
    private Color surfaceColor = Color.FromArgb(248, 250, 254);
    public int CornerRadius
    {
        get { return cornerRadius; }
        set { cornerRadius = Math.Max(8, value); Invalidate(); }
    }
    public Color OuterColor { get { return outerColor; } set { outerColor = value; Invalidate(); } }
    public Color SurfaceColor { get { return surfaceColor; } set { surfaceColor = value; Invalidate(); } }

    public ReferenceUiCard()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                 ControlStyles.SupportsTransparentBackColor, true);
        BackColor = surfaceColor;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(outerColor);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF bounds = new RectangleF(1f, 1f, Math.Max(2f, Width - 3f), Math.Max(2f, Height - 3f));
        using (GraphicsPath path = ReferenceUiDrawing.RoundedRectangle(bounds, cornerRadius))
        {
            using (SolidBrush fill = new SolidBrush(surfaceColor))
                e.Graphics.FillPath(fill, path);
        }
    }
}

public class ReferenceUiButton : Control
{
    private bool hovering;
    private bool pressing;
    private Color fillColor = Color.FromArgb(232, 236, 244);
    private Color canvasColor = Color.FromArgb(248, 250, 254);
    private int cornerRadius = 10;
    private Image image;
    private ContentAlignment imageAlign = ContentAlignment.MiddleCenter;
    public int CornerRadius
    {
        get { return cornerRadius; }
        set { cornerRadius = Math.Max(4, value); Invalidate(); }
    }
    public Color CanvasColor { get { return canvasColor; } set { canvasColor = value; Invalidate(); } }
    public Image Image { get { return image; } set { image = value; Invalidate(); } }
    public ContentAlignment ImageAlign { get { return imageAlign; } set { imageAlign = value; Invalidate(); } }
    public override Color BackColor
    {
        get { return fillColor; }
        set { fillColor = value; base.BackColor = Color.Transparent; Invalidate(); }
    }

    public ReferenceUiButton()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                 ControlStyles.SupportsTransparentBackColor | ControlStyles.Selectable, true);
        base.BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
        TabStop = true;
    }

    protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovering = false; pressing = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { pressing = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { pressing = false; Invalidate(); base.OnMouseUp(e); }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        Color background = Parent == null ? canvasColor : Parent.BackColor;
        e.Graphics.Clear(background);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF bounds = new RectangleF(1.2f, pressing ? 2.4f : 1.2f, Math.Max(2, Width - 3f), Math.Max(2, Height - 4f));
        Color baseColor = Enabled ? fillColor : Color.FromArgb(228, 232, 240);
        if (hovering && Enabled) baseColor = ControlPaint.Light(baseColor, .08f);
        using (GraphicsPath path = ReferenceUiDrawing.RoundedRectangle(bounds, cornerRadius))
        {
            Color top = ControlPaint.Light(baseColor, .28f);
            Color bottom = pressing ? ControlPaint.Dark(baseColor, .04f) : baseColor;
            using (LinearGradientBrush fill = new LinearGradientBrush(bounds, top, bottom, 90f))
                e.Graphics.FillPath(fill, path);
        }

        if (image != null)
        {
            int imageWidth = Math.Min(image.Width, Math.Max(1, Width - 12));
            int imageHeight = Math.Min(image.Height, Math.Max(1, Height - 12));
            Rectangle imageBounds = new Rectangle((Width - imageWidth) / 2, (Height - imageHeight) / 2, imageWidth, imageHeight);
            e.Graphics.DrawImage(image, imageBounds);
        }
        else
        {
            TextRenderer.DrawText(e.Graphics, Text, Font, Rectangle.Round(bounds), Enabled ? ForeColor : Color.FromArgb(140, 148, 163),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)
        {
            OnClick(EventArgs.Empty);
            e.Handled = true;
        }
        base.OnKeyDown(e);
    }
}

public static class ReferenceUiDwm
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public static void Apply(IntPtr handle)
    {
        try
        {
            int rounded = 2;
            DwmSetWindowAttribute(handle, 33, ref rounded, sizeof(int));
        }
        catch { }
    }
}

public sealed class PillToggleSwitch : CheckBox
{
    public PillToggleSwitch()
    {
        AutoSize = false;
        Size = new Size(46, 24);
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(Parent == null ? SystemColors.Control : Parent.BackColor);
        Rectangle track = new Rectangle(1, 2, Width - 2, Height - 4);
        using (GraphicsPath path = RoundedRectangle(track, track.Height / 2))
        using (SolidBrush trackBrush = new SolidBrush(Checked ? Color.FromArgb(47, 111, 237) : Color.FromArgb(190, 198, 211)))
        {
            e.Graphics.FillPath(trackBrush, path);
        }
        int diameter = Height - 8;
        int knobX = Checked ? Width - diameter - 4 : 4;
        using (SolidBrush knobBrush = new SolidBrush(Color.White))
        {
            e.Graphics.FillEllipse(knobBrush, knobX, 4, diameter, diameter);
        }
    }

    protected override void OnCheckedChanged(EventArgs e)
    {
        base.OnCheckedChanged(e);
        Invalidate();
    }

    private static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
    {
        int diameter = radius * 2;
        GraphicsPath path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

public sealed class OverlayPillForm : Form
{
    [StructLayout(LayoutKind.Sequential)] private struct PointNative { public int X; public int Y; public PointNative(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)] private struct SizeNative { public int CX; public int CY; public SizeNative(int cx, int cy) { CX = cx; CY = cy; } }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct BlendFunction { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr value);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UpdateLayeredWindow(IntPtr window, IntPtr destinationDc, ref PointNative destinationPoint, ref SizeNative size, IntPtr sourceDc, ref PointNative sourcePoint, int colorKey, ref BlendFunction blend, int flags);

    private string islandTitle = "桌面整理助手";
    private string islandDetail = "文件夹自动监控尚未开启";
    private Color statusColor = Color.FromArgb(107, 114, 128);
    private string glowMode = "Off";
    private float glowPhase;
    private readonly System.Threading.Timer animationTimer;
    private const int AnimationIntervalMilliseconds = 16;
    private volatile bool animationEnabled;
    private volatile bool animationFrameQueued;
    private Font titleFont;
    private Font detailFont;
    private Font chevronFont;
    private float layoutScale = 1f;
    private int animationFrameCount;
    private bool lastLayerUpdateSucceeded;
    public bool LastLayerUpdateSucceeded { get { return lastLayerUpdateSucceeded; } }
    public int AnimationFrameCount { get { return animationFrameCount; } }
    public int TargetFrameInterval { get { return AnimationIntervalMilliseconds; } }
    public bool IsMouseClickThrough { get { return IsHandleCreated && (GetWindowLong(Handle, -20) & 0x00000020) != 0; } }

    public OverlayPillForm()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        ConfigureLayoutScale(1f);
        animationTimer = new System.Threading.Timer(AnimationTick, null, System.Threading.Timeout.Infinite, System.Threading.Timeout.Infinite);
    }

    public float LayoutScale { get { return layoutScale; } }

    public void ConfigureLayoutScale(float scale)
    {
        float nextScale = Math.Max(0.75f, Math.Min(2f, scale));
        if (titleFont != null) titleFont.Dispose();
        if (detailFont != null) detailFont.Dispose();
        if (chevronFont != null) chevronFont.Dispose();
        layoutScale = nextScale;
        titleFont = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Bold, GraphicsUnit.Point);
        detailFont = new Font("Microsoft YaHei UI", 8f, FontStyle.Regular, GraphicsUnit.Point);
        chevronFont = new Font("Segoe UI", 17f, FontStyle.Regular, GraphicsUnit.Point);
        if (IsHandleCreated) UpdateLayer();
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            parameters.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            parameters.ExStyle |= 0x00080000; // WS_EX_LAYERED
            parameters.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT: mouse input passes to windows underneath
            return parameters;
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x0084) // WM_NCHITTEST
        {
            message.Result = new IntPtr(-1); // HTTRANSPARENT
            return;
        }
        base.WndProc(ref message);
    }

    public void SetContent(string title, string detail, Color dotColor, string mode)
    {
        islandTitle = String.IsNullOrWhiteSpace(title) ? "桌面整理助手" : title;
        islandDetail = detail ?? String.Empty;
        statusColor = dotColor;
        glowMode = String.IsNullOrWhiteSpace(mode) ? "Off" : mode;
        if (IsHandleCreated && glowMode != "Off") StartAnimation(); else StopAnimation();
        if (IsHandleCreated) UpdateLayer();
    }

    public void SavePreview(string path)
    {
        if (String.IsNullOrWhiteSpace(path)) return;
        using (Bitmap bitmap = CreateSurface()) bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    protected override void OnShown(EventArgs e) { base.OnShown(e); if (glowMode != "Off") StartAnimation(); UpdateLayer(); }
    protected override void OnFormClosed(FormClosedEventArgs e) { StopAnimation(); base.OnFormClosed(e); }
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            animationTimer.Dispose();
            if (titleFont != null) titleFont.Dispose();
            if (detailFont != null) detailFont.Dispose();
            if (chevronFont != null) chevronFont.Dispose();
        }
        base.Dispose(disposing);
    }

    private void StartAnimation()
    {
        animationEnabled = true;
        animationTimer.Change(0, AnimationIntervalMilliseconds);
    }

    private void StopAnimation()
    {
        animationEnabled = false;
        try { animationTimer.Change(System.Threading.Timeout.Infinite, System.Threading.Timeout.Infinite); } catch (ObjectDisposedException) { }
    }

    private void AnimationTick(object state)
    {
        if (!animationEnabled || IsDisposed || !IsHandleCreated) return;
        if (animationFrameQueued) return;
        animationFrameQueued = true;
        try
        {
            BeginInvoke((MethodInvoker)delegate
            {
                animationFrameQueued = false;
                if (!animationEnabled || IsDisposed) return;
                glowPhase += 0.0032f;
                if (glowPhase >= 1f) glowPhase -= 1f;
                animationFrameCount++;
                UpdateLayer();
            });
        }
        catch
        {
            animationFrameQueued = false;
        }
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); if (IsHandleCreated) UpdateLayer(); }
    protected override void OnPaint(PaintEventArgs e) { DrawSurface(e.Graphics, ClientSize.Width, ClientSize.Height); }

    private Bitmap CreateSurface()
    {
        Bitmap bitmap = new Bitmap(Math.Max(1, Width), Math.Max(1, Height), System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap)) DrawSurface(graphics, bitmap.Width, bitmap.Height);
        return bitmap;
    }

    private void DrawSurface(Graphics graphics, int width, int height)
    {
        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.CompositingQuality = CompositingQuality.HighQuality;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        float s = layoutScale;
        RectangleF bounds = new RectangleF(12.5f * s, 12.5f * s, Math.Max(2f, width - (25f * s)), Math.Max(2f, height - (25f * s)));
        using (GraphicsPath path = ReferenceUiDrawing.RoundedRectangle(bounds, 31f * s))
        {
            DrawFlowingGlow(graphics, path, bounds);
            using (SolidBrush background = new SolidBrush(Color.FromArgb(255, 8, 9, 11)))
            graphics.FillPath(background, path);
        }
        using (SolidBrush dot = new SolidBrush(statusColor)) graphics.FillEllipse(dot, 30f * s, 41f * s, 10f * s, 10f * s);
        TextFormatFlags flags = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis |
                                TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(graphics, islandTitle, titleFont, new Rectangle((int)(54f * s), (int)(20f * s), Math.Max(20, width - (int)(104f * s)), (int)(25f * s)), Color.White, flags);
        TextRenderer.DrawText(graphics, islandDetail, detailFont, new Rectangle((int)(54f * s), (int)(47f * s), Math.Max(20, width - (int)(104f * s)), (int)(22f * s)), Color.FromArgb(205, 211, 221), flags);
        TextRenderer.DrawText(graphics, "›", chevronFont, new Rectangle(width - (int)(43f * s), (int)(30f * s), (int)(20f * s), (int)(32f * s)), Color.FromArgb(139, 147, 160), flags | TextFormatFlags.HorizontalCenter);
    }

    private void DrawFlowingGlow(Graphics graphics, GraphicsPath path, RectangleF bounds)
    {
        Color[] colors;
        int broadAlpha;
        int edgeAlpha;
        if (glowMode == "Processing" || glowMode == "Complete")
        {
            colors = new Color[] { Color.FromArgb(31, 214, 151), Color.FromArgb(79, 255, 181), Color.FromArgb(22, 174, 126), Color.FromArgb(92, 234, 171), Color.FromArgb(31, 214, 151) };
            broadAlpha = glowMode == "Processing" ? 30 : 20;
            edgeAlpha = glowMode == "Processing" ? 255 : 213;
        }
        else if (glowMode == "Waiting")
        {
            colors = new Color[] { Color.FromArgb(255, 181, 71), Color.FromArgb(67, 196, 255), Color.FromArgb(142, 92, 246), Color.FromArgb(255, 181, 71), Color.FromArgb(255, 181, 71) };
            broadAlpha = 20;
            edgeAlpha = 188;
        }
        else if (glowMode == "Monitoring")
        {
            colors = new Color[] { Color.FromArgb(44, 128, 255), Color.FromArgb(79, 220, 255), Color.FromArgb(146, 91, 255), Color.FromArgb(65, 109, 255), Color.FromArgb(44, 128, 255) };
            broadAlpha = 18;
            edgeAlpha = 175;
        }
        else
        {
            colors = new Color[] { Color.FromArgb(93, 101, 116), Color.FromArgb(120, 129, 145), Color.FromArgb(93, 101, 116), Color.FromArgb(120, 129, 145), Color.FromArgb(93, 101, 116) };
            broadAlpha = 2;
            edgeAlpha = 15;
        }

        using (LinearGradientBrush outerBrush = CreateFlowBrush(bounds, colors, Math.Max(1, broadAlpha / 2)))
        using (Pen outerPen = new Pen(outerBrush, 18f * layoutScale))
        using (LinearGradientBrush broadBrush = CreateFlowBrush(bounds, colors, broadAlpha))
        using (Pen broadPen = new Pen(broadBrush, 9f * layoutScale))
        using (LinearGradientBrush middleBrush = CreateFlowBrush(bounds, colors, Math.Min(255, broadAlpha + 7)))
        using (Pen middlePen = new Pen(middleBrush, 4f * layoutScale))
        using (LinearGradientBrush edgeBrush = CreateFlowBrush(bounds, colors, edgeAlpha))
        using (Pen edgePen = new Pen(edgeBrush, 1.2f * layoutScale))
        {
            graphics.DrawPath(outerPen, path);
            graphics.DrawPath(broadPen, path);
            graphics.DrawPath(middlePen, path);
            graphics.DrawPath(edgePen, path);
        }
    }

    private LinearGradientBrush CreateFlowBrush(RectangleF bounds, Color[] colors, int alpha)
    {
        RectangleF gradientBounds = new RectangleF(bounds.Left - bounds.Width, bounds.Top, bounds.Width * 3f, bounds.Height);
        LinearGradientBrush brush = new LinearGradientBrush(gradientBounds, Color.Transparent, Color.Transparent, 0f);
        brush.WrapMode = WrapMode.Tile;
        ColorBlend blend = new ColorBlend(colors.Length);
        blend.Positions = new float[] { 0f, .25f, .5f, .75f, 1f };
        Color[] faded = new Color[colors.Length];
        for (int i = 0; i < colors.Length; i++) faded[i] = Color.FromArgb(alpha, colors[i]);
        blend.Colors = faded;
        brush.InterpolationColors = blend;
        brush.TranslateTransform(glowPhase * bounds.Width * 2f, 0f, MatrixOrder.Append);
        return brush;
    }

    private void UpdateLayer()
    {
        if (!IsHandleCreated || Width <= 0 || Height <= 0) return;
        using (Bitmap bitmap = CreateSurface())
        {
            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memoryDc = CreateCompatibleDC(screenDc);
            IntPtr bitmapHandle = IntPtr.Zero;
            IntPtr previous = IntPtr.Zero;
            try
            {
                bitmapHandle = bitmap.GetHbitmap(Color.FromArgb(0));
                previous = SelectObject(memoryDc, bitmapHandle);
                PointNative destination = new PointNative(Left, Top);
                PointNative source = new PointNative(0, 0);
                SizeNative size = new SizeNative(bitmap.Width, bitmap.Height);
                BlendFunction blend = new BlendFunction { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
                lastLayerUpdateSucceeded = UpdateLayeredWindow(Handle, screenDc, ref destination, ref size, memoryDc, ref source, 0, ref blend, 2);
            }
            finally
            {
                if (previous != IntPtr.Zero) SelectObject(memoryDc, previous);
                if (bitmapHandle != IntPtr.Zero) DeleteObject(bitmapHandle);
                DeleteDC(memoryDc);
                ReleaseDC(IntPtr.Zero, screenDc);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $winFormsTypeDefinition -ReferencedAssemblies $winFormsTypeReferences
}

[void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2)
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:files = [System.Collections.Generic.List[string]]::new()
$script:allItems = [System.Collections.Generic.List[System.Windows.Forms.ListViewItem]]::new()
$script:backgroundColor = [System.Drawing.Color]::White
$script:isConverting = $false
$script:updatingChecks = $false
$script:isLoadingState = $false
$script:lastActivePath = $null
$script:syncingVerticalScroll = $false
$script:resultPaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:workerProcess = $null
$script:workerTimer = $null
$script:stateSaveTimer = $null
$script:stateSaveDirty = $false
$script:previewProcess = $null
$script:previewTimer = $null
$script:previewRequestTimer = $null
$script:previewJob = $null
$script:pendingPreviewPath = $null
$script:displayedPreviewPath = $null
$script:displayedResultPath = $null
$script:processingItems = @()
$script:processingIndex = 0
$script:processingSuccess = 0
$script:processingFailed = 0
$script:processingSkipped = 0
$script:cancelRequested = $false
$script:currentJob = $null
$script:lastOutputDirectory = $null
$script:isSmokeRun = [bool]($SmokeTest -or $SmokeTestConversion -or $SmokeTestWebUi)
$script:dataDirectory = if ($script:isSmokeRun) {
    Join-Path ([System.IO.Path]::GetTempPath()) ('PngToJpg_SmokeState_' + [Guid]::NewGuid().ToString('N'))
} else {
    Join-Path $PSScriptRoot 'data'
}
$script:statePath = Join-Path $script:dataDirectory 'history.json'
. (Join-Path $PSScriptRoot 'modules\ImageApi.ps1')
. (Join-Path $PSScriptRoot 'modules\ImageApiSettings.ps1')
$script:imageApiConfig = New-ImageApiConfig
$apiConfigPath = Join-Path $script:dataDirectory 'image-api.json'
if (Test-Path -LiteralPath $apiConfigPath) {
    try {
        $savedApiConfig = Get-Content -LiteralPath $apiConfigPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in @($script:imageApiConfig.Keys)) {
            if ($savedApiConfig.Contains($key)) { $script:imageApiConfig[$key] = $savedApiConfig[$key] }
        }
    } catch { Write-Warning 'API 配置读取失败，请在图片清晰页面重新配置。' }
}
$script:workerScriptPath = Join-Path $PSScriptRoot 'modules\ImageWorker.ps1'
$script:documentWorkerScriptPath = Join-Path $PSScriptRoot 'modules\DocumentWorker.ps1'
$script:previewWorkerScriptPath = Join-Path $PSScriptRoot 'modules\PreviewWorker.ps1'
$script:magickPath = Join-Path $PSScriptRoot 'tools\imagemagick\magick.exe'
$script:pdfToPpmPath = Join-Path $PSScriptRoot 'tools\poppler\bin\pdftoppm.exe'
$script:realEsrganPath = Join-Path $PSScriptRoot 'tools\realesrgan\realesrgan-ncnn-vulkan.exe'
$script:realEsrganModelPath = Join-Path $PSScriptRoot 'tools\realesrgan\models'
. (Join-Path $PSScriptRoot 'modules\ImageLink.ps1')
Initialize-ImageLink
$script:localSearchWorkerScriptPath = Join-Path $PSScriptRoot 'modules\LocalSearchWorker.ps1'
. (Join-Path $PSScriptRoot 'modules\LocalSearch.ps1')
Initialize-LocalSearch
. (Join-Path $PSScriptRoot 'modules\PhotoshopAssistant.ps1')
Initialize-PhotoshopAssistant
$script:taskTempRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PngToJpg\Temp'
$script:powerShellPath = [Environment]::ProcessPath
$script:folderOrganizerScriptPath = Join-Path $PSScriptRoot 'modules\FolderOrganizer.ps1'
$script:folderOrganizerWorkerScriptPath = Join-Path $PSScriptRoot 'modules\FolderOrganizerWorker.ps1'
if (-not (Test-Path -LiteralPath $script:folderOrganizerScriptPath -PathType Leaf)) {
    throw "桌面整理模块不存在：$script:folderOrganizerScriptPath"
}
. $script:folderOrganizerScriptPath

$defaultDesktopPath = [Environment]::GetFolderPath('DesktopDirectory')
if ([string]::IsNullOrWhiteSpace($defaultDesktopPath)) {
    $defaultDesktopPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Desktop'
}
$defaultDingTalkDownloadPath = Get-DingTalkDownloadDirectory -DesktopPath $defaultDesktopPath
[void][System.IO.Directory]::CreateDirectory($defaultDingTalkDownloadPath)
$script:desktopProductHistoryPath = Join-Path $script:dataDirectory 'desktop-product-organizer-history'
$script:desktopProductLegacyUndoPath = Join-Path $script:dataDirectory 'desktop-product-organizer-undo.json'
Initialize-DesktopOrganizationHistory -HistoryPath $script:desktopProductHistoryPath -LegacyUndoPath $script:desktopProductLegacyUndoPath -RetentionDays 30
$script:desktopOrganizeScope = 'left'
$script:organizerPath = $defaultDingTalkDownloadPath
$script:organizerEnabled = $false
$script:organizerWatcher = $null
$script:organizerTimer = $null
$script:organizerWorkerProcess = $null
$script:organizerWorkerJob = $null
$script:organizerPending = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:organizerProcessed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:organizerLog = [System.Collections.Generic.List[string]]::new()
$script:organizerMinimumAgeSeconds = 5
$script:organizerIdlePollMilliseconds = 2000
$script:organizerActivePollMilliseconds = 200
$script:organizerQueueRunning = $false
$script:organizerDialog = $null
$script:organizerPage = $null
$script:activePage = 'Images'
$script:organizerDialogStatusLabel = $null
$script:organizerDialogStartButton = $null
$script:organizerDialogPathBox = $null
$script:organizerDialogBrowseButton = $null
$script:organizerDialogLogList = $null
$script:organizerDialogIslandToggle = $null
$script:organizerOpenSpreadsheetEnabled = $true
$script:organizerSpreadsheetScreenEnabled = $false
$script:organizerSpreadsheetScreenIndex = 0
$script:spreadsheetWindowMoveTimer = $null
$script:spreadsheetWindowMoveJobs = [System.Collections.Generic.List[object]]::new()
$script:spreadsheetWindowMoveHandles = [System.Collections.Generic.HashSet[long]]::new()
$script:organizerSubPage = 'Organizer'
$script:spreadsheetFolderQueue = [System.Collections.Generic.List[object]]::new()
$script:dynamicIslandEnabled = $false
$script:dynamicIslandForm = $null
$script:dynamicIslandTitleLabel = $null
$script:dynamicIslandDetailLabel = $null
$script:dynamicIslandStatusDot = $null
$script:dynamicIslandResetTimer = $null
$script:dynamicIslandOverrideTitle = $null
$script:dynamicIslandOverrideDetail = $null
$script:customNamingEnabled = $false
$script:customNamePrefix = '主图'
$script:customNameStart = 1

function New-UniqueOutputPath {
    param(
        [string]$Directory,
        [string]$BaseName,
        [string]$OutputExtension = 'jpg'
    )

    $normalizedExtension = $OutputExtension.Trim().TrimStart('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedExtension)) { $normalizedExtension = 'jpg' }
    $formatLabel = $normalizedExtension.ToUpperInvariant()
    $outputBaseName = "{0}_{1}" -f $BaseName, $formatLabel
    $candidate = Join-Path $Directory ("{0}.{1}" -f $outputBaseName, $normalizedExtension)
    $index = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Directory ("{0}_{1}.{2}" -f $outputBaseName, $index, $normalizedExtension)
        $index++
    }
    return $candidate
}

function New-ProcessedOutputPath {
    param([string]$Directory, [string]$BaseName, [string]$Extension, [string]$Suffix)
    $normalizedExtension = $Extension.Trim().TrimStart('.').ToLowerInvariant()
    $outputBaseName = $BaseName + $Suffix
    $candidate = Join-Path $Directory ("{0}.{1}" -f $outputBaseName, $normalizedExtension)
    $index = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Directory ("{0}_{1}.{2}" -f $outputBaseName, $index, $normalizedExtension)
        $index++
    }
    return $candidate
}

function New-SequentialOutputPath {
    param([string]$Directory, [string]$Prefix, [int]$StartNumber, [string]$Extension)
    $normalizedExtension = $Extension.Trim().TrimStart('.').ToLowerInvariant()
    $number = [Math]::Max(1, $StartNumber)
    do {
        $candidate = Join-Path $Directory ("{0}{1}.{2}" -f $Prefix, $number, $normalizedExtension)
        $number++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Get-JpegCodec {
    return [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object MimeType -eq 'image/jpeg' |
        Select-Object -First 1
}

function Convert-ImageFile {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [System.Drawing.Color]$Background,
        [int]$TargetWidth = 0,
        [int]$TargetHeight = 0
    )

    $source = $null
    $canvas = $null
    $graphics = $null
    $encoderParams = $null
    try {
        $source = [System.Drawing.Image]::FromFile($SourcePath, $true)
        $canvasWidth = if ($TargetWidth -gt 0) { $TargetWidth } else { $source.Width }
        $canvasHeight = if ($TargetHeight -gt 0) { $TargetHeight } else { $source.Height }
        $canvas = [System.Drawing.Bitmap]::new(
            $canvasWidth,
            $canvasHeight,
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
        )

        try {
            if ($source.HorizontalResolution -gt 0 -and $source.VerticalResolution -gt 0) {
                $canvas.SetResolution($source.HorizontalResolution, $source.VerticalResolution)
            }
        } catch { }

        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.Clear($Background)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        if ($TargetWidth -gt 0 -and $TargetHeight -gt 0) {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $scale = [Math]::Min($canvasWidth / [double]$source.Width, $canvasHeight / [double]$source.Height)
            $drawWidth = [Math]::Max(1, [int][Math]::Round($source.Width * $scale))
            $drawHeight = [Math]::Max(1, [int][Math]::Round($source.Height * $scale))
            $drawX = [int][Math]::Floor(($canvasWidth - $drawWidth) / 2)
            $drawY = [int][Math]::Floor(($canvasHeight - $drawHeight) / 2)
            $destinationRectangle = [System.Drawing.Rectangle]::new($drawX, $drawY, $drawWidth, $drawHeight)
            $graphics.DrawImage(
                $source,
                $destinationRectangle,
                0,
                0,
                $source.Width,
                $source.Height,
                [System.Drawing.GraphicsUnit]::Pixel
            )
        }
        else {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $graphics.DrawImageUnscaled($source, 0, 0)
        }

        foreach ($property in $source.PropertyItems) {
            try { $canvas.SetPropertyItem($property) } catch { }
        }

        $qualityEncoder = [System.Drawing.Imaging.Encoder]::Quality
        $encoderParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
        $encoderParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new($qualityEncoder, [long]100)
        $canvas.Save($DestinationPath, (Get-JpegCodec), $encoderParams)
    }
    finally {
        if ($encoderParams) { $encoderParams.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($canvas) { $canvas.Dispose() }
        if ($source) { $source.Dispose() }
    }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Save-AppState {
    param([switch]$Immediate)
    if ($script:isLoadingState) { return }
    if (-not $Immediate -and $script:stateSaveTimer) {
        $script:stateSaveDirty = $true
        $script:stateSaveTimer.Stop()
        $script:stateSaveTimer.Start()
        return
    }
    $script:stateSaveDirty = $false
    try {
        [System.IO.Directory]::CreateDirectory($script:dataDirectory) | Out-Null
        $records = @(
            foreach ($item in $script:allItems) {
                [PSCustomObject]@{
                    Path = [string]$item.Tag
                    Checked = [bool]$item.Checked
                    Status = [string]$item.SubItems[3].Text
                    AddedAt = [string]$item.Name
                    OutputPath = if ($script:resultPaths.ContainsKey([string]$item.Tag)) { $script:resultPaths[[string]$item.Tag] } else { $null }
                }
            }
        )
        $state = [PSCustomObject]@{
            Version = 10
            SavedAt = [DateTime]::Now.ToString('o')
            LastActivePath = $script:lastActivePath
            OutputSize = [string]$sizeCombo.SelectedItem
            OutputFormat = [string]$formatCombo.SelectedItem
            EnhancementMode = [string]$enhanceCombo.SelectedItem
            EnhancementStrength = [string]$strengthCombo.SelectedItem
            Scale = [string]$scaleCombo.SelectedItem
            ImageType = [string]$imageTypeCombo.SelectedItem
            PreserveAlpha = [bool]$preserveAlphaCheck.Checked
            OpenFolder = [bool]$openFolderCheck.Checked
            FaithfulMode = [bool]$faithfulCheck.Checked
            CustomWidth = [int]$finalWidthBox.Value
            CustomHeight = [int]$finalHeightBox.Value
            SameFolder = [bool]$sameFolder.Checked
            OutputDirectory = [string]$outputBox.Text
            CustomNamingEnabled = [bool]$script:customNamingEnabled
            CustomNamePrefix = [string]$script:customNamePrefix
            CustomNameStart = [int]$script:customNameStart
            DesktopOrganizerEnabled = [bool]$script:organizerEnabled
            DesktopOrganizerPath = [string]$script:organizerPath
            DingTalkOrganizerPath = [string]$script:organizerPath
            OpenSpreadsheetAfterOrganization = [bool]$script:organizerOpenSpreadsheetEnabled
            SpreadsheetTargetScreenEnabled = [bool]$script:organizerSpreadsheetScreenEnabled
            SpreadsheetTargetScreen = [int]($script:organizerSpreadsheetScreenIndex + 1)
            DynamicIslandEnabled = [bool]$script:dynamicIslandEnabled
            Records = $records
        }
        $json = $state | ConvertTo-Json -Depth 5
        $tempPath = $script:statePath + '.tmp'
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tempPath, $script:statePath, $true)
    }
    catch {
        $status.Text = '记录保存失败：' + $_.Exception.Message
    }
}

$form = [ReferenceUiForm]::new()
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
$form.Text = '图片处理与桌面文件整理'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1320, 900)
$form.MinimumSize = [System.Drawing.Size]::new(1180, 780)
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#E8EEF8')
$form.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
$form.AllowDrop = $true
$form.FormBorderStyle = 'None'
$form.Padding = [System.Windows.Forms.Padding]::new(10, 38, 10, 10)
$formIconPath = Join-Path $PSScriptRoot 'PngToJpg.ico'
if (Test-Path -LiteralPath $formIconPath -PathType Leaf) { $form.Icon = [System.Drawing.Icon]::new($formIconPath) }

$header = [ReferenceUiCard]::new()
$header.Dock = 'Top'
$header.Height = 104
$header.CornerRadius = 20
$form.Controls.Add($header)

$brandIcon = [System.Windows.Forms.PictureBox]::new()
$brandIcon.Location = [System.Drawing.Point]::new(24, 22)
$brandIcon.Size = [System.Drawing.Size]::new(42, 42)
$brandIcon.SizeMode = 'Zoom'
$brandIcon.BackColor = [System.Drawing.Color]::Transparent
if ($form.Icon) { $brandIcon.Image = $form.Icon.ToBitmap() }
$header.Controls.Add($brandIcon)

$title = [System.Windows.Forms.Label]::new()
$title.Text = '图片格式与尺寸转换'
$title.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 21, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#172033')
$title.AutoSize = $true
$title.Location = [System.Drawing.Point]::new(78, 19)
$header.Controls.Add($title)

$subtitle = [System.Windows.Forms.Label]::new()
$subtitle.Text = '质量 100 · 原尺寸或指定尺寸 · 本地离线处理'
$subtitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#687086')
$subtitle.AutoSize = $true
$subtitle.Location = [System.Drawing.Point]::new(81, 61)
$header.Controls.Add($subtitle)

$toolbar = [ReferenceUiCard]::new()
$toolbar.Dock = 'Top'
$toolbar.Height = 105
$toolbar.Padding = [System.Windows.Forms.Padding]::new(20, 14, 20, 10)
$toolbar.CornerRadius = 18
$form.Controls.Add($toolbar)
$toolbar.BringToFront()

function New-Button {
    param([string]$Text, [int]$Width, [System.Drawing.Color]$BackColor, [System.Drawing.Color]$ForeColor)
    $button = [ReferenceUiButton]::new()
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 38
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.Cursor = 'Hand'
    $button.CornerRadius = 10
    return $button
}

$windowButtonColor = [System.Drawing.ColorTranslator]::FromHtml('#E8EEF8')
$windowButtonTextColor = [System.Drawing.ColorTranslator]::FromHtml('#4B5870')
$minimizeGlyph = [string][char]0xE921
$maximizeGlyph = [string][char]0xE922
$restoreGlyph = [string][char]0xE923
$closeGlyph = [string][char]0xE8BB
$minimizeButton = New-Button $minimizeGlyph 44 $windowButtonColor $windowButtonTextColor
$maximizeButton = New-Button $maximizeGlyph 44 $windowButtonColor $windowButtonTextColor
$closeWindowButton = New-Button $closeGlyph 44 $windowButtonColor $windowButtonTextColor
foreach ($windowButton in @($minimizeButton, $maximizeButton, $closeWindowButton)) {
    $windowButton.Height = 30
    $windowButton.CornerRadius = 7
    $windowButton.CanvasColor = $form.BackColor
    $windowButton.Font = [System.Drawing.Font]::new('Segoe MDL2 Assets', 10)
    $windowButton.Anchor = 'Top,Right'
    $form.Controls.Add($windowButton)
}
$minimizeButton.Add_Click({ $form.WindowState = 'Minimized' })
$maximizeButton.Add_Click({
    $form.WindowState = if ($form.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
})
$closeWindowButton.Add_Click({ $form.Close() })

$addButton = New-Button '＋ 添加文件' 122 ([System.Drawing.ColorTranslator]::FromHtml('#2F6FED')) ([System.Drawing.Color]::White)
$addButton.Location = [System.Drawing.Point]::new(20, 14)
$toolbar.Controls.Add($addButton)

$clearButton = New-Button '清空列表' 98 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$clearButton.Location = [System.Drawing.Point]::new(152, 14)
$toolbar.Controls.Add($clearButton)

$previewButton = New-Button '预览选中' 98 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$previewButton.Location = [System.Drawing.Point]::new(260, 14)
$toolbar.Controls.Add($previewButton)

$selectAllCheck = [System.Windows.Forms.CheckBox]::new()
$selectAllCheck.Text = '全选转换'
$selectAllCheck.Checked = $true
$selectAllCheck.AutoSize = $true
$selectAllCheck.Location = [System.Drawing.Point]::new(378, 23)
$selectAllCheck.Cursor = 'Hand'
$toolbar.Controls.Add($selectAllCheck)

$invertButton = New-Button '反选' 70 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$invertButton.Location = [System.Drawing.Point]::new(480, 14)
$toolbar.Controls.Add($invertButton)

$scrollUpButton = New-Button '↑ 上翻' 68 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$scrollUpButton.Location = [System.Drawing.Point]::new(560, 14)
$toolbar.Controls.Add($scrollUpButton)

$scrollDownButton = New-Button '↓ 下翻' 68 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$scrollDownButton.Location = [System.Drawing.Point]::new(634, 14)
$toolbar.Controls.Add($scrollDownButton)

$scrollLeftButton = New-Button '←' 60 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$scrollLeftButton.Location = [System.Drawing.Point]::new(708, 14)
$toolbar.Controls.Add($scrollLeftButton)

$scrollRightButton = New-Button '→' 60 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$scrollRightButton.Location = [System.Drawing.Point]::new(774, 14)
$toolbar.Controls.Add($scrollRightButton)

# 上下浏览使用鼠标滚轮；左右浏览改用列表底部的长条滑块。
$scrollUpButton.Visible = $false
$scrollDownButton.Visible = $false
$scrollLeftButton.Visible = $false
$scrollRightButton.Visible = $false

function New-FolderNavigationIcon {
    param([System.Drawing.Color]$Color)
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $brush = [System.Drawing.SolidBrush]::new($Color)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.FillRectangle($brush, 3, 7, 12, 8)
        $backPoints = [System.Drawing.Point[]]@(
            [System.Drawing.Point]::new(3, 11), [System.Drawing.Point]::new(16, 11),
            [System.Drawing.Point]::new(19, 14), [System.Drawing.Point]::new(29, 14),
            [System.Drawing.Point]::new(27, 27), [System.Drawing.Point]::new(3, 27)
        )
        $graphics.FillPolygon($brush, $backPoints)
    }
    finally {
        $brush.Dispose()
        $graphics.Dispose()
    }
    return $bitmap
}

$organizerIconDefault = New-FolderNavigationIcon ([System.Drawing.ColorTranslator]::FromHtml('#7890B3'))
$organizerIconActive = New-FolderNavigationIcon ([System.Drawing.ColorTranslator]::FromHtml('#087A55'))
$organizerIconSelected = New-FolderNavigationIcon ([System.Drawing.Color]::White)
$script:navigationIconsDisposed = $false
function Dispose-NavigationIcons {
    if ($script:navigationIconsDisposed) { return }
    $organizerButton.Image = $null
    $organizerIconDefault.Dispose()
    $organizerIconActive.Dispose()
    $organizerIconSelected.Dispose()
    $script:navigationIconsDisposed = $true
}
$organizerButton = New-Button '' 56 ([System.Drawing.ColorTranslator]::FromHtml('#EEF2F8')) ([System.Drawing.ColorTranslator]::FromHtml('#7890B3'))
$organizerButton.Height = 56
$organizerButton.Image = $organizerIconDefault
$organizerButton.ImageAlign = 'MiddleCenter'
$organizerButton.AccessibleName = '钉钉下载文件夹自动整理'

$searchLabel = [System.Windows.Forms.Label]::new()
$searchLabel.Text = '搜索名称：'
$searchLabel.AutoSize = $true
$searchLabel.Location = [System.Drawing.Point]::new(20, 69)
$searchLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#4B556B')
$toolbar.Controls.Add($searchLabel)

$searchBox = [System.Windows.Forms.TextBox]::new()
$searchBox.Location = [System.Drawing.Point]::new(96, 64)
$searchBox.Height = 29
$searchBox.Width = 735
$searchBox.Anchor = 'Top,Left,Right'
$searchBox.PlaceholderText = '输入文件名关键词，列表会实时筛选'
$searchBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F9FBFF')
$searchBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
$searchBox.BorderStyle = 'FixedSingle'
$toolbar.Controls.Add($searchBox)

$list = [VerticalWheelListView]::new()
$list.Dock = 'Fill'
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $false
$list.ShowItemToolTips = $true
$list.CheckBoxes = $true
$list.MultiSelect = $true
$list.Scrollable = $true
$list.BorderStyle = 'None'
$list.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCFF')
$list.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
$list.AllowDrop = $true
[void]$list.Columns.Add('文件名', 300)
[void]$list.Columns.Add('尺寸', 125)
[void]$list.Columns.Add('大小', 90)
[void]$list.Columns.Add('状态', 135)

$listHost = [ReferenceUiCard]::new()
$listHost.Dock = 'Fill'
$listHost.Padding = [System.Windows.Forms.Padding]::new(12)
$listHost.CornerRadius = 18

$previewHost = [ReferenceUiCard]::new()
$previewHost.Dock = 'Fill'
$previewHost.Padding = [System.Windows.Forms.Padding]::new(10)
$previewHost.CornerRadius = 16

$previewLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$previewLayout.Dock = 'Fill'
$previewLayout.ColumnCount = 1
$previewLayout.RowCount = 3
$previewLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$previewLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 32)) | Out-Null
$previewLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$previewLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 58)) | Out-Null
$previewHost.Controls.Add($previewLayout)

$previewTitle = [System.Windows.Forms.Label]::new()
$previewTitle.Text = '图片预览'
$previewTitle.Dock = 'Fill'
$previewTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$previewTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#364158')
$previewLayout.Controls.Add($previewTitle, 0, 0)

$previewInfo = [System.Windows.Forms.Label]::new()
$previewInfo.Text = '选择一张图片查看预览'
$previewInfo.Dock = 'Fill'
$previewInfo.TextAlign = 'MiddleCenter'
$previewInfo.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#687086')
$previewInfo.AutoEllipsis = $true
$previewLayout.Controls.Add($previewInfo, 0, 2)

$compareLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$compareLayout.Dock = 'Fill'
$compareLayout.Margin = [System.Windows.Forms.Padding]::new(0)
$compareLayout.ColumnCount = 2
$compareLayout.RowCount = 2
$compareLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
$compareLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
$compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 25)) | Out-Null
$compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$previewLayout.Controls.Add($compareLayout, 0, 1)

$originalPreviewLabel = [System.Windows.Forms.Label]::new()
$originalPreviewLabel.Text = '原图'
$originalPreviewLabel.Dock = 'Fill'
$originalPreviewLabel.TextAlign = 'MiddleCenter'
$originalPreviewLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#4B556B')
$compareLayout.Controls.Add($originalPreviewLabel, 0, 0)

$resultPreviewLabel = [System.Windows.Forms.Label]::new()
$resultPreviewLabel.Text = '处理结果'
$resultPreviewLabel.Dock = 'Fill'
$resultPreviewLabel.TextAlign = 'MiddleCenter'
$resultPreviewLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#4B556B')
$compareLayout.Controls.Add($resultPreviewLabel, 1, 0)

$previewBox = [System.Windows.Forms.PictureBox]::new()
$previewBox.Dock = 'Fill'
$previewBox.Margin = [System.Windows.Forms.Padding]::new(0, 0, 4, 0)
$previewBox.SizeMode = 'Zoom'
$previewBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FBFCFF')
$previewBox.BorderStyle = 'FixedSingle'
$compareLayout.Controls.Add($previewBox, 0, 1)

$resultPreviewBox = [System.Windows.Forms.PictureBox]::new()
$resultPreviewBox.Dock = 'Fill'
$resultPreviewBox.Margin = [System.Windows.Forms.Padding]::new(4, 0, 0, 0)
$resultPreviewBox.SizeMode = 'Zoom'
$resultPreviewBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FBFCFF')
$resultPreviewBox.BorderStyle = 'FixedSingle'
$compareLayout.Controls.Add($resultPreviewBox, 1, 1)

$script:previewComparisonOrientation = 'SideBySide'
function Set-PreviewComparisonLayout {
    param([int]$ImageWidth, [int]$ImageHeight)

    if ($ImageWidth -le 0 -or $ImageHeight -le 0) { return }
    # 横图与接近方形的图片上下排列，获得完整预览宽度；明显竖图继续左右排列，获得更大的显示高度。
    $orientation = if (($ImageWidth / [double]$ImageHeight) -ge 0.90) { 'Stacked' } else { 'SideBySide' }
    if ($script:previewComparisonOrientation -eq $orientation) { return }

    $compareLayout.SuspendLayout()
    try {
        $compareLayout.Controls.Clear()
        $compareLayout.ColumnStyles.Clear()
        $compareLayout.RowStyles.Clear()
        if ($orientation -eq 'Stacked') {
            $compareLayout.ColumnCount = 1
            $compareLayout.RowCount = 4
            $compareLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
            $compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 25)) | Out-Null
            $compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
            $compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 25)) | Out-Null
            $compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
            $previewBox.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4)
            $resultPreviewBox.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
            $compareLayout.Controls.Add($originalPreviewLabel, 0, 0)
            $compareLayout.Controls.Add($previewBox, 0, 1)
            $compareLayout.Controls.Add($resultPreviewLabel, 0, 2)
            $compareLayout.Controls.Add($resultPreviewBox, 0, 3)
        } else {
            $compareLayout.ColumnCount = 2
            $compareLayout.RowCount = 2
            $compareLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
            $compareLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
            $compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 25)) | Out-Null
            $compareLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
            $previewBox.Margin = [System.Windows.Forms.Padding]::new(0, 0, 4, 0)
            $resultPreviewBox.Margin = [System.Windows.Forms.Padding]::new(4, 0, 0, 0)
            $compareLayout.Controls.Add($originalPreviewLabel, 0, 0)
            $compareLayout.Controls.Add($resultPreviewLabel, 1, 0)
            $compareLayout.Controls.Add($previewBox, 0, 1)
            $compareLayout.Controls.Add($resultPreviewBox, 1, 1)
        }
        $script:previewComparisonOrientation = $orientation
    }
    finally {
        $compareLayout.ResumeLayout($true)
    }
}

$contentSplit = [System.Windows.Forms.SplitContainer]::new()
$contentSplit.Dock = 'Fill'
$contentSplit.Size = [System.Drawing.Size]::new(800, 400)
$contentSplit.Orientation = 'Vertical'
$contentSplit.FixedPanel = 'Panel2'
$contentSplit.Panel1MinSize = 360
$contentSplit.Panel2MinSize = 360
$contentSplit.SplitterWidth = 6
$contentSplit.SplitterDistance = 540
$contentSplit.BackColor = [System.Drawing.Color]::Transparent
$contentSplit.Panel1.BackColor = [System.Drawing.Color]::Transparent
$contentSplit.Panel2.BackColor = [System.Drawing.Color]::Transparent

$listPanel = [System.Windows.Forms.Panel]::new()
$listPanel.Dock = 'Fill'
$listPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCFF')

$horizontalScrollHost = [System.Windows.Forms.Panel]::new()
$horizontalScrollHost.Dock = 'Bottom'
$horizontalScrollHost.Height = 27
$horizontalScrollHost.Padding = [System.Windows.Forms.Padding]::new(6, 3, 6, 3)
$horizontalScrollHost.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EEF2F8')

$horizontalScrollLabel = [System.Windows.Forms.Label]::new()
$horizontalScrollLabel.Text = '左右滑动'
$horizontalScrollLabel.Dock = 'Left'
$horizontalScrollLabel.Width = 68
$horizontalScrollLabel.TextAlign = 'MiddleLeft'
$horizontalScrollLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#687086')
$horizontalScrollHost.Controls.Add($horizontalScrollLabel)

$horizontalScroll = [System.Windows.Forms.HScrollBar]::new()
$horizontalScroll.Dock = 'Fill'
$horizontalScroll.Minimum = 0
$horizontalScroll.Maximum = 100
$horizontalScroll.SmallChange = 20
$horizontalScroll.LargeChange = 50
$horizontalScrollHost.Controls.Add($horizontalScroll)
$horizontalScroll.BringToFront()

$verticalScroll = [System.Windows.Forms.VScrollBar]::new()
$verticalScroll.Dock = 'Right'
$verticalScroll.Width = 24
$verticalScroll.Minimum = 0
$verticalScroll.Maximum = 0
$verticalScroll.SmallChange = 1
$verticalScroll.LargeChange = 1
$verticalScroll.Enabled = $false

$list.Margin = [System.Windows.Forms.Padding]::new(0)
$listPanel.Controls.Add($list)
$listHost.Controls.Add($listPanel)
$form.Controls.Add($listHost)
$listHost.BringToFront()

$settings = [ReferenceUiCard]::new()
$settings.Dock = 'Bottom'
$settings.Height = 290
$settings.Padding = [System.Windows.Forms.Padding]::new(20, 12, 20, 12)
$settings.CornerRadius = 18
$form.Controls.Add($settings)
$settings.BringToFront()

$sameFolder = [System.Windows.Forms.CheckBox]::new()
$sameFolder.Text = '保存到原图所在文件夹'
$sameFolder.Checked = $true
$sameFolder.AutoSize = $true
$sameFolder.Location = [System.Drawing.Point]::new(24, 18)
$settings.Controls.Add($sameFolder)

$outputBox = [System.Windows.Forms.TextBox]::new()
$outputBox.Location = [System.Drawing.Point]::new(24, 48)
$outputBox.Width = 520
$outputBox.Height = 28
$outputBox.Enabled = $false
$outputBox.ReadOnly = $true
$outputBox.PlaceholderText = '选择输出文件夹'
$settings.Controls.Add($outputBox)

$browseButton = New-Button '浏览…' 82 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$browseButton.Location = [System.Drawing.Point]::new(553, 45)
$browseButton.Height = 30
$browseButton.Enabled = $true
$settings.Controls.Add($browseButton)

$bgLabel = [System.Windows.Forms.Label]::new()
$bgLabel.Text = '透明区域背景：'
$bgLabel.AutoSize = $true
$bgLabel.Location = [System.Drawing.Point]::new(24, 94)
$settings.Controls.Add($bgLabel)

$bgCombo = [System.Windows.Forms.ComboBox]::new()
$bgCombo.DropDownStyle = 'DropDownList'
$bgCombo.Items.AddRange(@('白色', '黑色', '自定义…'))
$bgCombo.SelectedIndex = 0
$bgCombo.Location = [System.Drawing.Point]::new(128, 90)
$bgCombo.Width = 105
$settings.Controls.Add($bgCombo)

$colorPreview = [System.Windows.Forms.Panel]::new()
$colorPreview.Location = [System.Drawing.Point]::new(241, 91)
$colorPreview.Size = [System.Drawing.Size]::new(26, 24)
$colorPreview.BackColor = $script:backgroundColor
$colorPreview.BorderStyle = 'FixedSingle'
$settings.Controls.Add($colorPreview)

$sizeLabel = [System.Windows.Forms.Label]::new()
$sizeLabel.Text = '输出尺寸：'
$sizeLabel.AutoSize = $true
$sizeLabel.Location = [System.Drawing.Point]::new(294, 94)
$settings.Controls.Add($sizeLabel)

$sizeCombo = [System.Windows.Forms.ComboBox]::new()
$sizeCombo.DropDownStyle = 'DropDownList'
$sizeCombo.Items.AddRange(@('保持原始尺寸', '1650 × 1650', '1464 × 600', '970 × 600', '自定义尺寸'))
$sizeCombo.SelectedIndex = 0
$sizeCombo.Location = [System.Drawing.Point]::new(370, 90)
$sizeCombo.Width = 132
$settings.Controls.Add($sizeCombo)

$formatLabel = [System.Windows.Forms.Label]::new()
$formatLabel.Text = '输出格式：'
$formatLabel.AutoSize = $true
$formatLabel.Location = [System.Drawing.Point]::new(520, 94)
$settings.Controls.Add($formatLabel)

$formatCombo = [System.Windows.Forms.ComboBox]::new()
$formatCombo.DropDownStyle = 'DropDownList'
$formatCombo.Items.AddRange(@('JPG', 'PNG', 'WebP', '保持原格式', 'PDF', 'Word (.docx)', 'PowerPoint (.pptx)'))
$formatCombo.SelectedIndex = 0
$formatCombo.Location = [System.Drawing.Point]::new(596, 90)
$formatCombo.Width = 150
$settings.Controls.Add($formatCombo)

$enhanceLabel = [System.Windows.Forms.Label]::new()
$enhanceLabel.Text = '清晰增强：'
$enhanceLabel.AutoSize = $true
$enhanceLabel.Location = [System.Drawing.Point]::new(24, 136)
$settings.Controls.Add($enhanceLabel)

$enhanceCombo = [System.Windows.Forms.ComboBox]::new()
$enhanceCombo.DropDownStyle = 'DropDownList'
$enhanceCombo.Items.AddRange(@('关闭', '保守清晰', 'AI 模型高清', 'API 大模型清晰'))
$enhanceCombo.SelectedIndex = 0
$enhanceCombo.Location = [System.Drawing.Point]::new(100, 132)
$enhanceCombo.Width = 128
$settings.Controls.Add($enhanceCombo)

$strengthLabel = [System.Windows.Forms.Label]::new()
$strengthLabel.Text = '增强强度：'
$strengthLabel.AutoSize = $true
$strengthLabel.Location = [System.Drawing.Point]::new(244, 136)
$settings.Controls.Add($strengthLabel)

$strengthCombo = [System.Windows.Forms.ComboBox]::new()
$strengthCombo.DropDownStyle = 'DropDownList'
$strengthCombo.Items.AddRange(@('轻微', '标准', '较强'))
$strengthCombo.SelectedIndex = 1
$strengthCombo.Location = [System.Drawing.Point]::new(320, 132)
$strengthCombo.Width = 86
$settings.Controls.Add($strengthCombo)

$scaleLabel = [System.Windows.Forms.Label]::new()
$scaleLabel.Text = '放大倍数：'
$scaleLabel.AutoSize = $true
$scaleLabel.Location = [System.Drawing.Point]::new(422, 136)
$settings.Controls.Add($scaleLabel)

$scaleCombo = [System.Windows.Forms.ComboBox]::new()
$scaleCombo.DropDownStyle = 'DropDownList'
$scaleCombo.Items.AddRange(@('不放大', '2×', '4×'))
$scaleCombo.SelectedIndex = 0
$scaleCombo.Location = [System.Drawing.Point]::new(498, 132)
$scaleCombo.Width = 82
$settings.Controls.Add($scaleCombo)

$imageTypeLabel = [System.Windows.Forms.Label]::new()
$imageTypeLabel.Text = '图片类型：'
$imageTypeLabel.AutoSize = $true
$imageTypeLabel.Location = [System.Drawing.Point]::new(596, 136)
$settings.Controls.Add($imageTypeLabel)

$imageTypeCombo = [System.Windows.Forms.ComboBox]::new()
$imageTypeCombo.DropDownStyle = 'DropDownList'
$imageTypeCombo.Items.AddRange(@('商品照片', '插画'))
$imageTypeCombo.SelectedIndex = 0
$imageTypeCombo.Location = [System.Drawing.Point]::new(672, 132)
$imageTypeCombo.Width = 105
$settings.Controls.Add($imageTypeCombo)

$preserveAlphaCheck = [System.Windows.Forms.CheckBox]::new()
$preserveAlphaCheck.Text = '保留透明背景'
$preserveAlphaCheck.Checked = $true
$preserveAlphaCheck.AutoSize = $true
$preserveAlphaCheck.Location = [System.Drawing.Point]::new(798, 135)
$settings.Controls.Add($preserveAlphaCheck)

$openFolderCheck = [System.Windows.Forms.CheckBox]::new()
$openFolderCheck.Text = '完成后打开文件夹'
$openFolderCheck.Checked = $false
$openFolderCheck.AutoSize = $true
$openFolderCheck.Location = [System.Drawing.Point]::new(920, 135)
$settings.Controls.Add($openFolderCheck)

$finalSizeLabel = [System.Windows.Forms.Label]::new()
$finalSizeLabel.Text = '自定义最终尺寸：'
$finalSizeLabel.AutoSize = $true
$finalSizeLabel.Location = [System.Drawing.Point]::new(24, 176)
$settings.Controls.Add($finalSizeLabel)

$finalWidthBox = [System.Windows.Forms.NumericUpDown]::new()
$finalWidthBox.Minimum = 1
$finalWidthBox.Maximum = 50000
$finalWidthBox.Value = 1650
$finalWidthBox.Location = [System.Drawing.Point]::new(136, 172)
$finalWidthBox.Width = 82
$finalWidthBox.Enabled = $false
$settings.Controls.Add($finalWidthBox)

$sizeTimesLabel = [System.Windows.Forms.Label]::new()
$sizeTimesLabel.Text = '×'
$sizeTimesLabel.AutoSize = $true
$sizeTimesLabel.Location = [System.Drawing.Point]::new(226, 176)
$settings.Controls.Add($sizeTimesLabel)

$finalHeightBox = [System.Windows.Forms.NumericUpDown]::new()
$finalHeightBox.Minimum = 1
$finalHeightBox.Maximum = 50000
$finalHeightBox.Value = 1650
$finalHeightBox.Location = [System.Drawing.Point]::new(244, 172)
$finalHeightBox.Width = 82
$finalHeightBox.Enabled = $false
$settings.Controls.Add($finalHeightBox)

$faithfulCheck = [System.Windows.Forms.CheckBox]::new()
$faithfulCheck.Text = '忠实模式（文字/Logo，使用 RealESRNet）'
$faithfulCheck.Checked = $false
$faithfulCheck.AutoSize = $true
$faithfulCheck.Location = [System.Drawing.Point]::new(350, 175)
$settings.Controls.Add($faithfulCheck)

$aiWarning = [System.Windows.Forms.Label]::new()
$aiWarning.Text = 'AI 高清可能推测部分细节。包含重要文字、Logo、条码或精细结构时，建议使用保守清晰并检查结果。'
$aiWarning.AutoSize = $true
$aiWarning.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#A15C00')
$aiWarning.Location = [System.Drawing.Point]::new(24, 202)
$settings.Controls.Add($aiWarning)

$apiSettingsButton = New-Button 'API 接入配置' 136 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$apiSettingsButton.Location = [System.Drawing.Point]::new(710, 167)
$apiSettingsButton.Height = 32
$apiSettingsButton.Add_Click({ Show-ImageApiSettings })
$settings.Controls.Add($apiSettingsButton)
$enhancementControls = @($enhanceLabel, $enhanceCombo, $strengthLabel, $strengthCombo, $scaleLabel, $scaleCombo, $imageTypeLabel, $imageTypeCombo, $faithfulCheck, $apiSettingsButton)
foreach ($control in $enhancementControls) { $control.Visible = $false }
$aiWarning.Visible = $false

$progressBar = [System.Windows.Forms.ProgressBar]::new()
$progressBar.Location = [System.Drawing.Point]::new(24, 226)
$progressBar.Height = 18
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$settings.Controls.Add($progressBar)

$convertButton = New-Button '开始处理' 154 ([System.Drawing.ColorTranslator]::FromHtml('#4B86F8')) ([System.Drawing.Color]::White)
$convertButton.Anchor = 'Right,Bottom'
$convertButton.Location = [System.Drawing.Point]::new(988, 218)
$convertButton.Height = 42
$settings.Controls.Add($convertButton)

$cancelButton = New-Button '取消处理' 106 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#40506C'))
$cancelButton.Anchor = 'Right,Bottom'
$cancelButton.Location = [System.Drawing.Point]::new(872, 218)
$cancelButton.Height = 42
$cancelButton.Enabled = $false
$settings.Controls.Add($cancelButton)

$status = [System.Windows.Forms.Label]::new()
$status.Text = '拖入图片、PDF、Word 或 PPT 文件，或点击“添加文件”'
$status.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#687086')
$status.AutoSize = $true
$status.Anchor = 'Left,Bottom'
$status.Location = [System.Drawing.Point]::new(24, 249)
$settings.Controls.Add($status)

# 左侧工具栏与文件列表上下排列；右侧预览跨越这两行，从工具栏顶部一直延伸到内容区底部。
$leftWorkspaceLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$leftWorkspaceLayout.Dock = 'Fill'
$leftWorkspaceLayout.Margin = [System.Windows.Forms.Padding]::new(0)
$leftWorkspaceLayout.Padding = [System.Windows.Forms.Padding]::new(0)
$leftWorkspaceLayout.ColumnCount = 1
$leftWorkspaceLayout.RowCount = 2
$leftWorkspaceLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$leftWorkspaceLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 112)) | Out-Null
$leftWorkspaceLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$toolbar.Dock = 'Fill'
$toolbar.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4)
$listHost.Dock = 'Fill'
$listHost.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
$leftWorkspaceLayout.Controls.Add($toolbar, 0, 0)
$leftWorkspaceLayout.Controls.Add($listHost, 0, 1)
$contentSplit.Panel1.Controls.Add($leftWorkspaceLayout)
$contentSplit.Panel2.Controls.Add($previewHost)

# 使用固定行布局隔离页头、工作区和底部设置区，避免预览区延伸到设置区后方。
$mainLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$mainLayout.Dock = 'Fill'
$mainLayout.Margin = [System.Windows.Forms.Padding]::new(0)
$mainLayout.Padding = [System.Windows.Forms.Padding]::new(4)
$mainLayout.BackColor = [System.Drawing.Color]::Transparent
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 3
$mainLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$mainLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 108)) | Out-Null
$mainLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$mainLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 220)) | Out-Null
foreach ($section in @($header, $contentSplit, $settings)) {
    $section.Dock = 'Fill'
    $section.Margin = [System.Windows.Forms.Padding]::new(6, 4, 6, 4)
}
$mainLayout.Controls.Add($header, 0, 0)
$mainLayout.Controls.Add($contentSplit, 0, 1)
$mainLayout.Controls.Add($settings, 0, 2)
foreach ($control in @($enhancementControls) + @($aiWarning)) { $settings.Controls.Remove($control) }
. (Join-Path $PSScriptRoot 'modules\ClarityPage.ps1')
$form.Add_Disposed({ Close-ClarityWorkspace })

# 按用户界面示意图增加左侧功能导航；文件夹整理固定在主页、图片设置之后的第三个位置。
$navigationSidebar = [ReferenceUiCard]::new()
$navigationSidebar.Dock = 'Fill'
$navigationSidebar.Margin = [System.Windows.Forms.Padding]::new(6)
$navigationSidebar.CornerRadius = 20

$navigationBrand = [System.Windows.Forms.PictureBox]::new()
$navigationBrand.Location = [System.Drawing.Point]::new(19, 18)
$navigationBrand.Size = [System.Drawing.Size]::new(40, 40)
$navigationBrand.SizeMode = 'Zoom'
$navigationBrand.BackColor = [System.Drawing.Color]::Transparent
if ($form.Icon) { $navigationBrand.Image = $form.Icon.ToBitmap() }
$navigationSidebar.Controls.Add($navigationBrand)

function New-NavigationButton {
    param([int]$Glyph, [int]$Top, [string]$AccessibleName)
    $button = New-Button ([string][char]$Glyph) 52 ([System.Drawing.ColorTranslator]::FromHtml('#EDF2FA')) ([System.Drawing.ColorTranslator]::FromHtml('#8B9AB2'))
    $button.Height = 50
    $button.Location = [System.Drawing.Point]::new(13, $Top)
    $button.CornerRadius = 13
    $button.Font = [System.Drawing.Font]::new('Segoe MDL2 Assets', 18)
    $button.AccessibleName = $AccessibleName
    return $button
}

$homeNavigationButton = New-NavigationButton 0xE80F 88 '图片处理主页'
$homeNavigationButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#74A7FF')
$homeNavigationButton.ForeColor = [System.Drawing.Color]::White
$navigationSidebar.Controls.Add($homeNavigationButton)

$settingsNavigationButton = New-NavigationButton 0xE8A9 152 '图片输出设置'
$navigationSidebar.Controls.Add($settingsNavigationButton)

$organizerButton.Size = [System.Drawing.Size]::new(52, 50)
$organizerButton.Location = [System.Drawing.Point]::new(13, 216)
$organizerButton.CornerRadius = 13
$navigationSidebar.Controls.Add($organizerButton)

$enhanceNavigationButton = New-NavigationButton 0xE735 280 '预留功能'
$enhanceNavigationButton.Cursor = 'Default'
$navigationSidebar.Controls.Add($enhanceNavigationButton)

$searchNavigationButton = New-NavigationButton 0xE700 344 '搜索与批量操作'
$navigationSidebar.Controls.Add($searchNavigationButton)

$changelogNavigationButton = New-NavigationButton 0xE946 408 '更新日志'
$navigationSidebar.Controls.Add($changelogNavigationButton)

$imageApiNavigationButton = New-NavigationButton 0xE790 472 '图片清晰 · 本地与 API'
$navigationSidebar.Controls.Add($imageApiNavigationButton)

$organizerToolTip = [System.Windows.Forms.ToolTip]::new()
$organizerToolTip.SetToolTip($homeNavigationButton, '图片处理主页')
$organizerToolTip.SetToolTip($settingsNavigationButton, '输出尺寸与格式设置')
$organizerToolTip.SetToolTip($organizerButton, '钉钉下载文件夹自动整理')
$organizerToolTip.SetToolTip($enhanceNavigationButton, '预留功能')
$organizerToolTip.SetToolTip($imageApiNavigationButton, '图片清晰 · 本地增强 / 大模型 API')
$organizerToolTip.SetToolTip($searchNavigationButton, '搜索与批量操作')
$organizerToolTip.SetToolTip($changelogNavigationButton, '查看更新日志')

# 文件夹整理是主窗口内的独立页面，不再创建第二个窗口。
$organizerPage = [System.Windows.Forms.TableLayoutPanel]::new()
$organizerPage.Dock = 'Fill'
$organizerPage.Margin = [System.Windows.Forms.Padding]::new(0)
$organizerPage.Padding = [System.Windows.Forms.Padding]::new(4)
$organizerPage.BackColor = [System.Drawing.Color]::Transparent
$organizerPage.ColumnCount = 1
$organizerPage.RowCount = 2
$organizerPage.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$organizerPage.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 108)) | Out-Null
$organizerPage.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$organizerPage.Visible = $false
$script:organizerPage = $organizerPage

$organizerHeader = [ReferenceUiCard]::new()
$organizerHeader.Dock = 'Fill'
$organizerHeader.Margin = [System.Windows.Forms.Padding]::new(6, 4, 6, 4)
$organizerHeader.CornerRadius = 18
$organizerPageTitle = [System.Windows.Forms.Label]::new()
$organizerPageTitle.Text = '钉钉下载文件夹自动整理'
$organizerPageTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
$organizerPageTitle.AutoSize = $true
$organizerPageTitle.Location = [System.Drawing.Point]::new(28, 22)
$organizerHeader.Controls.Add($organizerPageTitle)
$organizerPageSubtitle = [System.Windows.Forms.Label]::new()
$organizerPageSubtitle.Text = '支持自动监控、批量选择和一次拖入多个项目文件夹 · 本地后台处理'
$organizerPageSubtitle.AutoSize = $true
$organizerPageSubtitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#788196')
$organizerPageSubtitle.Location = [System.Drawing.Point]::new(31, 67)
$organizerHeader.Controls.Add($organizerPageSubtitle)

$organizerModeButton = New-Button '自动整理' 108 ([System.Drawing.ColorTranslator]::FromHtml('#2F6FED')) ([System.Drawing.Color]::White)
$organizerModeButton.Location = [System.Drawing.Point]::new(900, 31)
$organizerModeButton.Anchor = 'Top,Right'
$organizerHeader.Controls.Add($organizerModeButton)

$spreadsheetModeButton = New-Button '批量打开表格' 138 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$spreadsheetModeButton.Location = [System.Drawing.Point]::new(1020, 31)
$spreadsheetModeButton.Anchor = 'Top,Right'
$organizerHeader.Controls.Add($spreadsheetModeButton)
$organizerPage.Controls.Add($organizerHeader, 0, 0)

$organizerContent = [ReferenceUiCard]::new()
$organizerContent.Dock = 'Fill'
$organizerContent.Margin = [System.Windows.Forms.Padding]::new(6, 4, 6, 6)
$organizerContent.CornerRadius = 18
$organizerPage.Controls.Add($organizerContent, 0, 1)

$organizerPathLabel = [System.Windows.Forms.Label]::new()
$organizerPathLabel.Text = '钉钉目录：'
$organizerPathLabel.AutoSize = $true
$organizerPathLabel.Location = [System.Drawing.Point]::new(26, 28)
$organizerContent.Controls.Add($organizerPathLabel)

$organizerPathBox = [System.Windows.Forms.TextBox]::new()
$organizerPathBox.Text = $script:organizerPath
$organizerPathBox.Location = [System.Drawing.Point]::new(105, 24)
$organizerPathBox.Size = [System.Drawing.Size]::new(700, 28)
$organizerPathBox.Anchor = 'Top,Left,Right'
$organizerContent.Controls.Add($organizerPathBox)
$script:organizerDialogPathBox = $organizerPathBox

$organizerPathBrowseButton = New-Button '浏览…' 82 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$organizerPathBrowseButton.Location = [System.Drawing.Point]::new(820, 21)
$organizerPathBrowseButton.Height = 32
$organizerPathBrowseButton.Anchor = 'Top,Right'
$organizerContent.Controls.Add($organizerPathBrowseButton)
$script:organizerDialogBrowseButton = $organizerPathBrowseButton

$organizerStatus = [System.Windows.Forms.Label]::new()
$organizerStatus.AutoSize = $true
$organizerStatus.Location = [System.Drawing.Point]::new(28, 67)
$organizerContent.Controls.Add($organizerStatus)
$script:organizerDialogStatusLabel = $organizerStatus

$organizerStartButton = New-Button '开始自动监控' 140 ([System.Drawing.ColorTranslator]::FromHtml('#17A673')) ([System.Drawing.Color]::White)
$organizerStartButton.Location = [System.Drawing.Point]::new(26, 94)
$organizerContent.Controls.Add($organizerStartButton)
$script:organizerDialogStartButton = $organizerStartButton

$organizerSingleButton = New-Button '添加一个文件夹…' 146 ([System.Drawing.ColorTranslator]::FromHtml('#2F6FED')) ([System.Drawing.Color]::White)
$organizerSingleButton.Location = [System.Drawing.Point]::new(178, 94)
$organizerContent.Controls.Add($organizerSingleButton)

$organizerBatchButton = New-Button '批量添加子文件夹…' 166 ([System.Drawing.ColorTranslator]::FromHtml('#2F6FED')) ([System.Drawing.Color]::White)
$organizerBatchButton.Location = [System.Drawing.Point]::new(336, 94)
$organizerContent.Controls.Add($organizerBatchButton)

$organizerOpenButton = New-Button '打开钉钉目录' 124 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$organizerOpenButton.Location = [System.Drawing.Point]::new(514, 94)
$organizerContent.Controls.Add($organizerOpenButton)

$organizerSpreadsheetToggle = [PillToggleSwitch]::new()
$organizerSpreadsheetToggle.Location = [System.Drawing.Point]::new(690, 98)
$organizerSpreadsheetToggle.Anchor = 'Top,Right'
$organizerSpreadsheetToggle.Checked = $script:organizerOpenSpreadsheetEnabled
$organizerContent.Controls.Add($organizerSpreadsheetToggle)

$organizerSpreadsheetLabel = [System.Windows.Forms.Label]::new()
$organizerSpreadsheetLabel.Text = '整理后打开表格'
$organizerSpreadsheetLabel.AutoSize = $true
$organizerSpreadsheetLabel.Location = [System.Drawing.Point]::new(744, 95)
$organizerSpreadsheetLabel.Anchor = 'Top,Right'
$organizerSpreadsheetLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$organizerContent.Controls.Add($organizerSpreadsheetLabel)

$organizerSpreadsheetDescription = [System.Windows.Forms.Label]::new()
$organizerSpreadsheetDescription.Text = '单个与批量整理均遵守此开关'
$organizerSpreadsheetDescription.AutoSize = $true
$organizerSpreadsheetDescription.Location = [System.Drawing.Point]::new(744, 117)
$organizerSpreadsheetDescription.Anchor = 'Top,Right'
$organizerSpreadsheetDescription.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#788196')
$organizerSpreadsheetDescription.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 8)
$organizerContent.Controls.Add($organizerSpreadsheetDescription)

$organizerSpreadsheetScreenToggle = [PillToggleSwitch]::new()
$organizerSpreadsheetScreenToggle.Location = [System.Drawing.Point]::new(796, 139)
$organizerSpreadsheetScreenToggle.Anchor = 'Top,Right'
$organizerSpreadsheetScreenToggle.Checked = $script:organizerSpreadsheetScreenEnabled
$organizerContent.Controls.Add($organizerSpreadsheetScreenToggle)

$organizerSpreadsheetScreenLabel = [System.Windows.Forms.Label]::new()
$organizerSpreadsheetScreenLabel.Text = '指定表格屏幕'
$organizerSpreadsheetScreenLabel.AutoSize = $true
$organizerSpreadsheetScreenLabel.Location = [System.Drawing.Point]::new(850, 136)
$organizerSpreadsheetScreenLabel.Anchor = 'Top,Right'
$organizerSpreadsheetScreenLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$organizerContent.Controls.Add($organizerSpreadsheetScreenLabel)

$organizerSpreadsheetScreenCombo = [System.Windows.Forms.ComboBox]::new()
$organizerSpreadsheetScreenCombo.DropDownStyle = 'DropDownList'
$organizerSpreadsheetScreenCombo.Location = [System.Drawing.Point]::new(962, 132)
$organizerSpreadsheetScreenCombo.Size = [System.Drawing.Size]::new(144, 28)
$organizerSpreadsheetScreenCombo.Anchor = 'Top,Right'
$screenNumber = 0
foreach ($screen in @([System.Windows.Forms.Screen]::AllScreens | Sort-Object DeviceName)) {
    $screenNumber++
    $screenLabel = if ($screen.Primary) { "第 $screenNumber 个屏幕（主屏）" } else { "第 $screenNumber 个屏幕" }
    [void]$organizerSpreadsheetScreenCombo.Items.Add($screenLabel)
}
if ($organizerSpreadsheetScreenCombo.Items.Count -eq 0) { [void]$organizerSpreadsheetScreenCombo.Items.Add('第 1 个屏幕') }
$organizerSpreadsheetScreenCombo.SelectedIndex = [Math]::Min($script:organizerSpreadsheetScreenIndex, $organizerSpreadsheetScreenCombo.Items.Count - 1)
$organizerSpreadsheetScreenCombo.Enabled = $script:organizerSpreadsheetScreenEnabled
$organizerContent.Controls.Add($organizerSpreadsheetScreenCombo)

$organizerIslandToggle = [PillToggleSwitch]::new()
$organizerIslandToggle.Location = [System.Drawing.Point]::new(935, 98)
$organizerIslandToggle.Anchor = 'Top,Right'
$organizerIslandToggle.Checked = $script:dynamicIslandEnabled
$organizerContent.Controls.Add($organizerIslandToggle)
$script:organizerDialogIslandToggle = $organizerIslandToggle

$organizerIslandLabel = [System.Windows.Forms.Label]::new()
$organizerIslandLabel.Text = '显示灵动岛'
$organizerIslandLabel.AutoSize = $true
$organizerIslandLabel.Location = [System.Drawing.Point]::new(989, 95)
$organizerIslandLabel.Anchor = 'Top,Right'
$organizerIslandLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$organizerContent.Controls.Add($organizerIslandLabel)

$organizerIslandDescription = [System.Windows.Forms.Label]::new()
$organizerIslandDescription.Text = '屏幕顶部显示批量整理状态'
$organizerIslandDescription.AutoSize = $true
$organizerIslandDescription.Location = [System.Drawing.Point]::new(989, 117)
$organizerIslandDescription.Anchor = 'Top,Right'
$organizerIslandDescription.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#788196')
$organizerIslandDescription.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 8)
$organizerContent.Controls.Add($organizerIslandDescription)

$organizerDropCard = [ReferenceUiCard]::new()
$organizerDropCard.Location = [System.Drawing.Point]::new(26, 178)
$organizerDropCard.Size = [System.Drawing.Size]::new(1080, 112)
$organizerDropCard.Anchor = 'Top,Left,Right'
$organizerDropCard.CornerRadius = 16
$organizerDropCard.OuterColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
$organizerDropCard.SurfaceColor = [System.Drawing.ColorTranslator]::FromHtml('#EEF4FF')
$organizerDropCard.AllowDrop = $true
$organizerContent.Controls.Add($organizerDropCard)

$organizerDropTitle = [System.Windows.Forms.Label]::new()
$organizerDropTitle.Text = '把多个项目文件夹一次拖到这里'
$organizerDropTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$organizerDropTitle.AutoSize = $true
$organizerDropTitle.Location = [System.Drawing.Point]::new(26, 19)
$organizerDropTitle.BackColor = [System.Drawing.Color]::Transparent
$organizerDropCard.Controls.Add($organizerDropTitle)
$organizerDropDescription = [System.Windows.Forms.Label]::new()
$organizerDropDescription.Text = '支持任意位置的多个文件夹；全部加入后台队列并逐个安全整理，不覆盖同名内容。批量添加按钮会加入所选父目录下的全部第一层子文件夹。'
$organizerDropDescription.Location = [System.Drawing.Point]::new(29, 54)
$organizerDropDescription.Size = [System.Drawing.Size]::new(1010, 42)
$organizerDropDescription.Anchor = 'Top,Left,Right'
$organizerDropDescription.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#52627D')
$organizerDropDescription.BackColor = [System.Drawing.Color]::Transparent
$organizerDropCard.Controls.Add($organizerDropDescription)

$organizerLogTitle = [System.Windows.Forms.Label]::new()
$organizerLogTitle.Text = '批量整理记录与队列'
$organizerLogTitle.AutoSize = $true
$organizerLogTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$organizerLogTitle.Location = [System.Drawing.Point]::new(28, 310)
$organizerContent.Controls.Add($organizerLogTitle)

$organizerLogHost = [ReferenceUiCard]::new()
$organizerLogHost.Location = [System.Drawing.Point]::new(26, 338)
$organizerLogHost.Size = [System.Drawing.Size]::new(1080, 240)
$organizerLogHost.Anchor = 'Top,Bottom,Left,Right'
$organizerLogHost.Padding = [System.Windows.Forms.Padding]::new(12)
$organizerLogHost.CornerRadius = 14
$organizerLogHost.OuterColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
$organizerLogHost.SurfaceColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCFF')
$organizerContent.Controls.Add($organizerLogHost)

$organizerLogList = [System.Windows.Forms.ListBox]::new()
$organizerLogList.Dock = 'Fill'
$organizerLogList.BorderStyle = 'None'
$organizerLogList.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCFF')
$organizerLogList.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
$organizerLogList.HorizontalScrollbar = $true
foreach ($entry in $script:organizerLog) { [void]$organizerLogList.Items.Add($entry) }
$organizerLogHost.Controls.Add($organizerLogList)
$script:organizerDialogLogList = $organizerLogList

$organizerPathBrowseButton.Add_Click({
    $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderDialog.Description = '选择钉钉专用下载目录（请勿选择桌面根目录）'
    $folderDialog.InitialDirectory = $organizerPathBox.Text
    if ($folderDialog.ShowDialog($form) -eq 'OK') { $organizerPathBox.Text = $folderDialog.SelectedPath }
    $folderDialog.Dispose()
})
$organizerStartButton.Add_Click({
    if ($script:organizerEnabled -and $script:organizerWatcher) { Stop-DesktopOrganizer }
    else { [void](Start-DesktopOrganizer -Path $organizerPathBox.Text) }
})
$organizerSingleButton.Add_Click({
    $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderDialog.Description = '选择一个需要立即整理的项目文件夹'
    $folderDialog.InitialDirectory = $script:organizerPath
    if ($folderDialog.ShowDialog($form) -eq 'OK') { Add-OrganizerFoldersBatch -Paths @($folderDialog.SelectedPath) }
    $folderDialog.Dispose()
})
$organizerBatchButton.Add_Click({
    $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderDialog.Description = '选择父目录；其中全部第一层子文件夹会加入批量整理队列'
    $folderDialog.InitialDirectory = $script:organizerPath
    if ($folderDialog.ShowDialog($form) -eq 'OK') {
        $children = @(Get-ChildItem -LiteralPath $folderDialog.SelectedPath -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        Add-OrganizerFoldersBatch -Paths $children
    }
    $folderDialog.Dispose()
})
$organizerOpenButton.Add_Click({ Open-DesktopOrganizerPath })
$organizerIslandToggle.Add_CheckedChanged({
    param($sender, $eventArgs)
    $script:dynamicIslandEnabled = [bool]$sender.Checked
    if ($script:isLoadingState) { return }
    if ($script:dynamicIslandEnabled) { Show-DynamicIsland } else { Hide-DynamicIsland }
    Save-AppState
})
$organizerSpreadsheetToggle.Add_CheckedChanged({
    param($sender, $eventArgs)
    $script:organizerOpenSpreadsheetEnabled = [bool]$sender.Checked
    if (-not $script:isLoadingState) { Save-AppState }
})
$organizerSpreadsheetScreenToggle.Add_CheckedChanged({
    param($sender, $eventArgs)
    $script:organizerSpreadsheetScreenEnabled = [bool]$sender.Checked
    $organizerSpreadsheetScreenCombo.Enabled = $script:organizerSpreadsheetScreenEnabled
    if (-not $script:isLoadingState) { Save-AppState }
})
$organizerSpreadsheetScreenCombo.Add_SelectedIndexChanged({
    param($sender, $eventArgs)
    if ($sender.SelectedIndex -ge 0) { $script:organizerSpreadsheetScreenIndex = [int]$sender.SelectedIndex }
    if (-not $script:isLoadingState) { Save-AppState }
})

# 备用的表格批量打开页与整理队列完全分开，只查找和打开文件，不移动任何内容。
$spreadsheetOpenContent = [ReferenceUiCard]::new()
$spreadsheetOpenContent.Dock = 'Fill'
$spreadsheetOpenContent.Margin = [System.Windows.Forms.Padding]::new(6, 4, 6, 6)
$spreadsheetOpenContent.CornerRadius = 18
$spreadsheetOpenContent.Visible = $false
$organizerPage.Controls.Add($spreadsheetOpenContent, 0, 1)

$spreadsheetPageTitle = [System.Windows.Forms.Label]::new()
$spreadsheetPageTitle.Text = '批量打开已整理文件夹中的表格'
$spreadsheetPageTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$spreadsheetPageTitle.AutoSize = $true
$spreadsheetPageTitle.Location = [System.Drawing.Point]::new(28, 24)
$spreadsheetOpenContent.Controls.Add($spreadsheetPageTitle)

$spreadsheetPageDescription = [System.Windows.Forms.Label]::new()
$spreadsheetPageDescription.Text = '把已经整理好的多个项目文件夹拖到下方；这里只查找表格，不会再次整理或移动文件。手动“打开全部”不受自动开关限制。'
$spreadsheetPageDescription.AutoSize = $true
$spreadsheetPageDescription.Location = [System.Drawing.Point]::new(31, 61)
$spreadsheetPageDescription.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#52627D')
$spreadsheetOpenContent.Controls.Add($spreadsheetPageDescription)

$spreadsheetAddParentButton = New-Button '添加父目录下的项目…' 180 ([System.Drawing.ColorTranslator]::FromHtml('#2F6FED')) ([System.Drawing.Color]::White)
$spreadsheetAddParentButton.Location = [System.Drawing.Point]::new(26, 91)
$spreadsheetOpenContent.Controls.Add($spreadsheetAddParentButton)

$spreadsheetClearButton = New-Button '清空列表' 104 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
$spreadsheetClearButton.Location = [System.Drawing.Point]::new(218, 91)
$spreadsheetOpenContent.Controls.Add($spreadsheetClearButton)

$spreadsheetOpenAllButton = New-Button '打开全部表格' 142 ([System.Drawing.ColorTranslator]::FromHtml('#17A673')) ([System.Drawing.Color]::White)
$spreadsheetOpenAllButton.Location = [System.Drawing.Point]::new(936, 91)
$spreadsheetOpenAllButton.Anchor = 'Top,Right'
$spreadsheetOpenContent.Controls.Add($spreadsheetOpenAllButton)

$spreadsheetDropCard = [ReferenceUiCard]::new()
$spreadsheetDropCard.Location = [System.Drawing.Point]::new(26, 142)
$spreadsheetDropCard.Size = [System.Drawing.Size]::new(1080, 108)
$spreadsheetDropCard.Anchor = 'Top,Left,Right'
$spreadsheetDropCard.CornerRadius = 16
$spreadsheetDropCard.OuterColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
$spreadsheetDropCard.SurfaceColor = [System.Drawing.ColorTranslator]::FromHtml('#EEF4FF')
$spreadsheetDropCard.AllowDrop = $true
$spreadsheetOpenContent.Controls.Add($spreadsheetDropCard)

$spreadsheetDropTitle = [System.Windows.Forms.Label]::new()
$spreadsheetDropTitle.Text = '把多个已整理项目文件夹拖到这里'
$spreadsheetDropTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$spreadsheetDropTitle.AutoSize = $true
$spreadsheetDropTitle.Location = [System.Drawing.Point]::new(26, 18)
$spreadsheetDropTitle.BackColor = [System.Drawing.Color]::Transparent
$spreadsheetDropCard.Controls.Add($spreadsheetDropTitle)

$spreadsheetDropDescription = [System.Windows.Forms.Label]::new()
$spreadsheetDropDescription.Text = '支持一次拖入多个项目根文件夹，也支持直接拖入“项目名 源文件”文件夹；找到的表格会先列出，点击按钮后统一打开。'
$spreadsheetDropDescription.Location = [System.Drawing.Point]::new(29, 53)
$spreadsheetDropDescription.Size = [System.Drawing.Size]::new(1010, 40)
$spreadsheetDropDescription.Anchor = 'Top,Left,Right'
$spreadsheetDropDescription.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#52627D')
$spreadsheetDropDescription.BackColor = [System.Drawing.Color]::Transparent
$spreadsheetDropCard.Controls.Add($spreadsheetDropDescription)

$spreadsheetListTitle = [System.Windows.Forms.Label]::new()
$spreadsheetListTitle.Text = '待打开表格列表'
$spreadsheetListTitle.AutoSize = $true
$spreadsheetListTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$spreadsheetListTitle.Location = [System.Drawing.Point]::new(28, 270)
$spreadsheetOpenContent.Controls.Add($spreadsheetListTitle)

$spreadsheetListHost = [ReferenceUiCard]::new()
$spreadsheetListHost.Location = [System.Drawing.Point]::new(26, 299)
$spreadsheetListHost.Size = [System.Drawing.Size]::new(1080, 245)
$spreadsheetListHost.Anchor = 'Top,Bottom,Left,Right'
$spreadsheetListHost.Padding = [System.Windows.Forms.Padding]::new(12)
$spreadsheetListHost.CornerRadius = 14
$spreadsheetListHost.OuterColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
$spreadsheetListHost.SurfaceColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCFF')
$spreadsheetOpenContent.Controls.Add($spreadsheetListHost)

$spreadsheetList = [System.Windows.Forms.ListView]::new()
$spreadsheetList.Dock = 'Fill'
$spreadsheetList.View = 'Details'
$spreadsheetList.FullRowSelect = $true
$spreadsheetList.GridLines = $false
$spreadsheetList.ShowItemToolTips = $true
$spreadsheetList.BorderStyle = 'None'
$spreadsheetList.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCFF')
$spreadsheetList.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
[void]$spreadsheetList.Columns.Add('项目文件夹', 310)
[void]$spreadsheetList.Columns.Add('找到的表格', 500)
[void]$spreadsheetList.Columns.Add('状态', 150)
$spreadsheetListHost.Controls.Add($spreadsheetList)

$spreadsheetStatus = [System.Windows.Forms.Label]::new()
$spreadsheetStatus.Text = '尚未添加文件夹'
$spreadsheetStatus.AutoSize = $true
$spreadsheetStatus.Location = [System.Drawing.Point]::new(339, 100)
$spreadsheetStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#687086')
$spreadsheetOpenContent.Controls.Add($spreadsheetStatus)

function Update-OrganizerSubPageUi {
    $showSpreadsheetPage = $script:organizerSubPage -eq 'Spreadsheets'
    $organizerContent.Visible = -not $showSpreadsheetPage
    $spreadsheetOpenContent.Visible = $showSpreadsheetPage
    if ($showSpreadsheetPage) { $spreadsheetOpenContent.BringToFront() } else { $organizerContent.BringToFront() }
    $organizerModeButton.BackColor = if ($showSpreadsheetPage) { [System.Drawing.ColorTranslator]::FromHtml('#E8ECF4') } else { [System.Drawing.ColorTranslator]::FromHtml('#2F6FED') }
    $organizerModeButton.ForeColor = if ($showSpreadsheetPage) { [System.Drawing.ColorTranslator]::FromHtml('#364158') } else { [System.Drawing.Color]::White }
    $spreadsheetModeButton.BackColor = if ($showSpreadsheetPage) { [System.Drawing.ColorTranslator]::FromHtml('#2F6FED') } else { [System.Drawing.ColorTranslator]::FromHtml('#E8ECF4') }
    $spreadsheetModeButton.ForeColor = if ($showSpreadsheetPage) { [System.Drawing.Color]::White } else { [System.Drawing.ColorTranslator]::FromHtml('#364158') }
    $organizerPageSubtitle.Text = if ($showSpreadsheetPage) {
        '拖入已整理项目文件夹，批量查找并打开表格 · 不移动任何文件'
    } else {
        '支持自动监控、批量选择和一次拖入多个项目文件夹 · 本地后台处理'
    }
}

function Show-OrganizerSubPage {
    param([ValidateSet('Organizer', 'Spreadsheets')][string]$Page)
    $script:organizerSubPage = $Page
    Update-OrganizerSubPageUi
    Update-Layout
}

$organizerModeButton.Add_Click({ Show-OrganizerSubPage -Page 'Organizer' })
$spreadsheetModeButton.Add_Click({ Show-OrganizerSubPage -Page 'Spreadsheets' })

# 更新日志同样使用主窗口内页面，内容来自随程序发布的 CHANGELOG.md。
$changelogPage = [System.Windows.Forms.TableLayoutPanel]::new()
$changelogPage.Dock = 'Fill'
$changelogPage.Margin = [System.Windows.Forms.Padding]::new(0)
$changelogPage.Padding = [System.Windows.Forms.Padding]::new(4)
$changelogPage.BackColor = [System.Drawing.Color]::Transparent
$changelogPage.ColumnCount = 1
$changelogPage.RowCount = 2
$changelogPage.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$changelogPage.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 108)) | Out-Null
$changelogPage.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$changelogPage.Visible = $false

$changelogHeader = [ReferenceUiCard]::new()
$changelogHeader.Dock = 'Fill'
$changelogHeader.Margin = [System.Windows.Forms.Padding]::new(6, 4, 6, 4)
$changelogHeader.CornerRadius = 18
$changelogTitle = [System.Windows.Forms.Label]::new()
$changelogTitle.Text = '更新日志'
$changelogTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
$changelogTitle.AutoSize = $true
$changelogTitle.Location = [System.Drawing.Point]::new(28, 22)
$changelogHeader.Controls.Add($changelogTitle)
$changelogSubtitle = [System.Windows.Forms.Label]::new()
$changelogSubtitle.Text = '查看图片处理、文件夹整理和灵动岛的功能更新与修复记录'
$changelogSubtitle.AutoSize = $true
$changelogSubtitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#788196')
$changelogSubtitle.Location = [System.Drawing.Point]::new(31, 67)
$changelogHeader.Controls.Add($changelogSubtitle)
$changelogPage.Controls.Add($changelogHeader, 0, 0)

$changelogContent = [ReferenceUiCard]::new()
$changelogContent.Dock = 'Fill'
$changelogContent.Margin = [System.Windows.Forms.Padding]::new(6, 4, 6, 6)
$changelogContent.Padding = [System.Windows.Forms.Padding]::new(28, 22, 28, 22)
$changelogContent.CornerRadius = 18
$changelogPage.Controls.Add($changelogContent, 0, 1)

$changelogBox = [System.Windows.Forms.RichTextBox]::new()
$changelogBox.Dock = 'Fill'
$changelogBox.ReadOnly = $true
$changelogBox.BorderStyle = 'None'
$changelogBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
$changelogBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
$changelogBox.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 10)
$changelogBox.DetectUrls = $false
$changelogBox.ScrollBars = 'Vertical'
$changelogBox.TabStop = $false
$changelogContent.Controls.Add($changelogBox)

function Load-ChangelogContent {
    $changelogPath = Join-Path $PSScriptRoot 'CHANGELOG.md'
    $fallbackText = '暂时没有可显示的更新日志。'
    try {
        if (-not (Test-Path -LiteralPath $changelogPath -PathType Leaf)) {
            $changelogBox.Text = $fallbackText
            return
        }
        $lines = @(Get-Content -LiteralPath $changelogPath -Encoding UTF8 -ErrorAction Stop)
        $changelogBox.Clear()
        foreach ($line in $lines) {
            $displayLine = [string]$line
            $fontSize = 10.0
            $fontStyle = [System.Drawing.FontStyle]::Regular
            $color = [System.Drawing.ColorTranslator]::FromHtml('#314463')
            if ($displayLine -match '^#\s+(.+)$') {
                $displayLine = $Matches[1]
                $fontSize = 17.0
                $fontStyle = [System.Drawing.FontStyle]::Bold
                $color = [System.Drawing.ColorTranslator]::FromHtml('#17233A')
            } elseif ($displayLine -match '^##\s+(.+)$') {
                $displayLine = $Matches[1]
                $fontSize = 12.5
                $fontStyle = [System.Drawing.FontStyle]::Bold
                $color = [System.Drawing.ColorTranslator]::FromHtml('#2F6FED')
            } elseif ($displayLine -match '^-\s+(.+)$') {
                $displayLine = '• ' + $Matches[1]
            }
            $lineFont = [System.Drawing.Font]::new('Microsoft YaHei UI', $fontSize, $fontStyle)
            try {
                $changelogBox.SelectionStart = $changelogBox.TextLength
                $changelogBox.SelectionLength = 0
                $changelogBox.SelectionFont = $lineFont
                $changelogBox.SelectionColor = $color
                $changelogBox.AppendText($displayLine + [Environment]::NewLine)
            }
            finally { $lineFont.Dispose() }
        }
        if ([string]::IsNullOrWhiteSpace($changelogBox.Text)) { $changelogBox.Text = $fallbackText }
        $changelogBox.SelectionStart = 0
        $changelogBox.ScrollToCaret()
    }
    catch {
        $changelogBox.Text = '更新日志暂时无法读取，请稍后重新打开此页面。'
    }
}
Load-ChangelogContent

$appShell = [System.Windows.Forms.TableLayoutPanel]::new()
$appShell.Dock = 'Fill'
$appShell.Margin = [System.Windows.Forms.Padding]::new(0)
$appShell.Padding = [System.Windows.Forms.Padding]::new(0)
$appShell.ColumnCount = 2
$appShell.RowCount = 1
$appShell.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 84)) | Out-Null
$appShell.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$appShell.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$appShell.Controls.Add($navigationSidebar, 0, 0)
$appShell.Controls.Add($mainLayout, 1, 0)
$appShell.Controls.Add($clarityPage, 1, 0)
$appShell.Controls.Add($organizerPage, 1, 0)
$appShell.Controls.Add($changelogPage, 1, 0)
$form.Controls.Add($appShell)
foreach ($windowButton in @($minimizeButton, $maximizeButton, $closeWindowButton)) { $windowButton.BringToFront() }

function Apply-ReferenceUiStyle {
    param([System.Windows.Forms.Control]$Parent)
    foreach ($control in $Parent.Controls) {
        if ($control -is [System.Windows.Forms.Label] -or $control -is [System.Windows.Forms.CheckBox]) {
            $control.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
        }
        elseif ($control -is [System.Windows.Forms.TextBox]) {
            $control.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F9FBFF')
            $control.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
            $control.BorderStyle = 'FixedSingle'
        }
        elseif ($control -is [System.Windows.Forms.ComboBox]) {
            $control.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
            $control.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
            $control.FlatStyle = 'Flat'
        }
        elseif ($control -is [System.Windows.Forms.NumericUpDown]) {
            $control.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFE')
            $control.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#314463')
            $control.BorderStyle = 'FixedSingle'
        }
        elseif ($control -is [System.Windows.Forms.TableLayoutPanel]) {
            $control.BackColor = [System.Drawing.Color]::Transparent
        }
        if ($control.HasChildren) { Apply-ReferenceUiStyle $control }
    }
}
Apply-ReferenceUiStyle $form
$organizerDropTitle.BackColor = [System.Drawing.Color]::Transparent
$organizerDropDescription.BackColor = [System.Drawing.Color]::Transparent
$spreadsheetDropTitle.BackColor = [System.Drawing.Color]::Transparent
$spreadsheetDropDescription.BackColor = [System.Drawing.Color]::Transparent

function Update-ChangelogNavigationUi {
    $imageApiNavigationButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml($(if ($script:activePage -eq 'Enhancement') { '#74A7FF' } else { '#EDF2FA' }))
    $imageApiNavigationButton.ForeColor = $(if ($script:activePage -eq 'Enhancement') { [System.Drawing.Color]::White } else { [System.Drawing.ColorTranslator]::FromHtml('#8B9AB2') })
    if ($script:activePage -eq 'Changelog') {
        $changelogNavigationButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#74A7FF')
        $changelogNavigationButton.ForeColor = [System.Drawing.Color]::White
    } else {
        $changelogNavigationButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EDF2FA')
        $changelogNavigationButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#8B9AB2')
    }
}

function Show-ImageWorkspace {
    param([System.Windows.Forms.Control]$FocusControl, [switch]$Enhancement)
    if ($script:isConverting) { return }
    $script:activePage = if ($Enhancement) { 'Enhancement' } else { 'Images' }
    $organizerPage.Visible = $false
    $changelogPage.Visible = $false
    $mainLayout.Visible = -not $Enhancement
    $clarityPage.Visible = [bool]$Enhancement
    if ($Enhancement) { $clarityPage.BringToFront(); Update-ClarityMode } else { $mainLayout.BringToFront() }
    $homeNavigationButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml($(if ($Enhancement) { '#EDF2FA' } else { '#74A7FF' }))
    $homeNavigationButton.ForeColor = $(if ($Enhancement) { [System.Drawing.ColorTranslator]::FromHtml('#8B9AB2') } else { [System.Drawing.Color]::White })
    $title.Text = '图片格式与尺寸转换'
    $subtitle.Text = '质量 100 · 原尺寸或指定尺寸 · 本地离线处理'
    Update-DesktopOrganizerUi
    Update-ChangelogNavigationUi
    if ($FocusControl) { [void]$FocusControl.Focus() }
}

function Show-DesktopOrganizerPage {
    $script:activePage = 'Organizer'
    $mainLayout.Visible = $false
    $clarityPage.Visible = $false
    $changelogPage.Visible = $false
    $organizerPage.Visible = $true
    $organizerPage.BringToFront()
    $homeNavigationButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EDF2FA')
    $homeNavigationButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#8B9AB2')
    Update-DesktopOrganizerUi
    Update-ChangelogNavigationUi
    [void]$organizerPage.Focus()
    if ((Get-Variable webHost -Scope Script -ErrorAction SilentlyContinue) -and $script:webHost.Loaded) {
        [void]$script:webHost.CoreWebView2.ExecuteScriptAsync("navigatePage('organizer')")
        $script:webHost.BringToFront()
    }
}

function Show-ChangelogPage {
    $script:activePage = 'Changelog'
    $mainLayout.Visible = $false
    $clarityPage.Visible = $false
    $organizerPage.Visible = $false
    $changelogPage.Visible = $true
    $changelogPage.BringToFront()
    $homeNavigationButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EDF2FA')
    $homeNavigationButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#8B9AB2')
    Update-DesktopOrganizerUi
    Update-ChangelogNavigationUi
    Load-ChangelogContent
    [void]$changelogPage.Focus()
}

$homeNavigationButton.Add_Click({ Show-ImageWorkspace -FocusControl $list })
$settingsNavigationButton.Add_Click({ Show-ImageWorkspace -FocusControl $sizeCombo })
$imageApiNavigationButton.Add_Click({ Show-ImageWorkspace -Enhancement -FocusControl $script:clarity.Mode })
$searchNavigationButton.Add_Click({ Show-ImageWorkspace -FocusControl $searchBox })
$changelogNavigationButton.Add_Click({ Show-ChangelogPage })

function Update-Layout {
    $navigationBrand.Left = [Math]::Floor(($navigationSidebar.ClientSize.Width - $navigationBrand.Width) / 2)
    foreach ($navigationButton in @($homeNavigationButton, $settingsNavigationButton, $organizerButton, $enhanceNavigationButton, $searchNavigationButton, $changelogNavigationButton, $imageApiNavigationButton)) {
        $navigationButton.Left = [Math]::Floor(($navigationSidebar.ClientSize.Width - $navigationButton.Width) / 2)
    }
    $closeWindowButton.Location = [System.Drawing.Point]::new($form.ClientSize.Width - $closeWindowButton.Width - 8, 4)
    $maximizeButton.Location = [System.Drawing.Point]::new($closeWindowButton.Left - $maximizeButton.Width, 4)
    $minimizeButton.Location = [System.Drawing.Point]::new($maximizeButton.Left - $minimizeButton.Width, 4)
    $maximizeButton.Text = if ($form.WindowState -eq 'Maximized') { $restoreGlyph } else { $maximizeGlyph }
    $searchBox.Width = [Math]::Max(260, $toolbar.ClientSize.Width - $searchBox.Left - 24)
    $sameFolder.Location = [Drawing.Point]::new(24,20)
    $outputBox.Location = [Drawing.Point]::new(230,16)
    $outputBox.Width = [Math]::Max(180,$settings.ClientSize.Width-350)
    $browseButton.Location = [Drawing.Point]::new($settings.ClientSize.Width-102,13)
    $bgLabel.Top=64; $bgCombo.Top=60; $colorPreview.Top=61
    $sizeLabel.Top=64; $sizeCombo.Top=60; $formatLabel.Top=64; $formatCombo.Top=60
    $finalSizeLabel.Top=106; $finalWidthBox.Top=102; $sizeTimesLabel.Top=106; $finalHeightBox.Top=102
    $preserveAlphaCheck.Location=[Drawing.Point]::new(500,105)
    $openFolderCheck.Location=[Drawing.Point]::new(700,105)
    $progressBar.Top=161; $convertButton.Top=148; $cancelButton.Top=148; $status.Top=190
    $convertButton.Left = $settings.ClientSize.Width - $convertButton.Width - 20
    $cancelButton.Left = $convertButton.Left - $cancelButton.Width - 10
    $progressBar.Width = [Math]::Max(160, $cancelButton.Left - $progressBar.Left - 14)
    $status.Left = 24
    $maximumStatusWidth = $convertButton.Left - $status.Left - 12
    if ($maximumStatusWidth -gt 0) { $status.MaximumSize = [System.Drawing.Size]::new($maximumStatusWidth, 0) }
    if ($organizerHeader.ClientSize.Width -gt 400) {
        $spreadsheetModeButton.Left = $organizerHeader.ClientSize.Width - $spreadsheetModeButton.Width - 28
        $organizerModeButton.Left = $spreadsheetModeButton.Left - $organizerModeButton.Width - 12
    }
    if ($organizerContent.ClientSize.Width -gt 200) {
        $organizerPathBrowseButton.Left = $organizerContent.ClientSize.Width - $organizerPathBrowseButton.Width - 26
        $organizerPathBox.Width = [Math]::Max(240, $organizerPathBrowseButton.Left - $organizerPathBox.Left - 14)
        $organizerIslandLabel.Left = $organizerContent.ClientSize.Width - 147
        $organizerIslandDescription.Left = $organizerIslandLabel.Left
        $organizerIslandToggle.Left = $organizerIslandLabel.Left - 54
        $organizerSpreadsheetLabel.Left = $organizerIslandToggle.Left - 190
        $organizerSpreadsheetDescription.Left = $organizerSpreadsheetLabel.Left
        $organizerSpreadsheetToggle.Left = $organizerSpreadsheetLabel.Left - 54
        $organizerSpreadsheetScreenCombo.Left = $organizerContent.ClientSize.Width - $organizerSpreadsheetScreenCombo.Width - 26
        $organizerSpreadsheetScreenLabel.Left = $organizerSpreadsheetScreenCombo.Left - $organizerSpreadsheetScreenLabel.Width - 12
        $organizerSpreadsheetScreenToggle.Left = $organizerSpreadsheetScreenLabel.Left - 54
        $organizerDropCard.Width = [Math]::Max(300, $organizerContent.ClientSize.Width - 52)
        $organizerDropDescription.Width = [Math]::Max(240, $organizerDropCard.ClientSize.Width - 58)
        $organizerLogHost.Width = [Math]::Max(300, $organizerContent.ClientSize.Width - 52)
        $organizerLogHost.Height = [Math]::Max(120, $organizerContent.ClientSize.Height - $organizerLogHost.Top - 25)
    }
    if ($spreadsheetOpenContent.ClientSize.Width -gt 200) {
        $spreadsheetOpenAllButton.Left = $spreadsheetOpenContent.ClientSize.Width - $spreadsheetOpenAllButton.Width - 26
        $spreadsheetDropCard.Width = [Math]::Max(300, $spreadsheetOpenContent.ClientSize.Width - 52)
        $spreadsheetDropDescription.Width = [Math]::Max(240, $spreadsheetDropCard.ClientSize.Width - 58)
        $spreadsheetListHost.Width = [Math]::Max(300, $spreadsheetOpenContent.ClientSize.Width - 52)
        $spreadsheetListHost.Height = [Math]::Max(120, $spreadsheetOpenContent.ClientSize.Height - $spreadsheetListHost.Top - 25)
        if ($spreadsheetList.ClientSize.Width -gt 500) {
            $spreadsheetList.Columns[0].Width = [Math]::Max(220, [int]($spreadsheetList.ClientSize.Width * 0.30))
            $spreadsheetList.Columns[2].Width = 140
            $spreadsheetList.Columns[1].Width = [Math]::Max(260, $spreadsheetList.ClientSize.Width - $spreadsheetList.Columns[0].Width - $spreadsheetList.Columns[2].Width - 8)
        }
    }
}

function Get-SelectedOutputSize {
    switch ($sizeCombo.SelectedIndex) {
        1 { return [System.Drawing.Size]::new(1650, 1650) }
        2 { return [System.Drawing.Size]::new(1464, 600) }
        3 { return [System.Drawing.Size]::new(970, 600) }
        4 { return [System.Drawing.Size]::new([int]$finalWidthBox.Value, [int]$finalHeightBox.Value) }
        default { return [System.Drawing.Size]::Empty }
    }
}

function Get-SelectedScale {
    switch ($scaleCombo.SelectedIndex) { 1 { return 2 } 2 { return 4 } default { return 1 } }
}

function Get-SelectedOutputFormat {
    switch ($formatCombo.SelectedIndex) {
        1 { return 'png' }
        2 { return 'webp' }
        3 {
            if ($list.SelectedItems.Count -gt 0) {
                $sourceExtension = [System.IO.Path]::GetExtension([string]$list.SelectedItems[0].Tag).TrimStart('.').ToLowerInvariant()
                if ($sourceExtension -in @('jpg', 'jpeg', 'jfif')) { return 'jpg' }
                if ($sourceExtension -eq 'webp') { return 'webp' }
            }
            return 'png'
        }
        4 { return 'pdf' }
        5 { return 'docx' }
        6 { return 'pptx' }
        default { return 'jpg' }
    }
}

function Update-EnhancementControls {
    $mode = [string]$enhanceCombo.SelectedItem
    $isEnhanced = $mode -in @('保守清晰', 'AI 模型高清')
    $isAi = $mode -eq 'AI 模型高清'
    $isApi = $mode -eq 'API 大模型清晰'
    $faithfulAvailable = (Test-Path -LiteralPath (Join-Path $script:realEsrganModelPath 'realesrnet-x4plus.param') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $script:realEsrganModelPath 'realesrnet-x4plus.bin') -PathType Leaf)
    $strengthCombo.Enabled = $isEnhanced
    $scaleCombo.Enabled = $isEnhanced
    $imageTypeCombo.Enabled = $isAi
    $faithfulCheck.Enabled = $isAi -and $imageTypeCombo.SelectedIndex -eq 0 -and $faithfulAvailable
    $faithfulCheck.Text = if ($faithfulAvailable) { '忠实模式（文字/Logo，使用 RealESRNet）' } else { '忠实模式（官方便携包暂未提供模型）' }
    if (-not $faithfulAvailable) { $faithfulCheck.Checked = $false }
    $aiWarning.Visible = $false
    $aiWarning.Text = if ($isApi) { '开始处理会上传勾选图片并消耗 API 额度；大模型可能改变文字和细节，请检查结果。' } else { 'AI 高清可能推测部分细节。包含重要文字、Logo、条码或精细结构时，建议使用保守清晰并检查结果。' }
    $convertButton.Text = '开始转换'
    if ($isAi -and $scaleCombo.SelectedIndex -eq 0) { $scaleCombo.SelectedIndex = 1 }
    $finalWidthBox.Enabled = $sizeCombo.SelectedIndex -eq 4
    $finalHeightBox.Enabled = $sizeCombo.SelectedIndex -eq 4
}

function Get-LocalEngineStatusText {
    $hasMagick = Test-Path -LiteralPath $script:magickPath -PathType Leaf
    $requiredAiFiles = @(
        $script:realEsrganPath,
        (Join-Path $script:realEsrganModelPath 'realesrgan-x4plus.param'),
        (Join-Path $script:realEsrganModelPath 'realesrgan-x4plus.bin'),
        (Join-Path $script:realEsrganModelPath 'realesrgan-x4plus-anime.param'),
        (Join-Path $script:realEsrganModelPath 'realesrgan-x4plus-anime.bin')
    )
    $hasAiFiles = -not ($requiredAiFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1)
    $probePath = Join-Path (Split-Path -Parent $script:realEsrganPath) 'engine-status.json'
    $vulkanVerified = $false
    $gpuName = $null
    if ($hasAiFiles -and (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        try {
            $probe = Get-Content -LiteralPath $probePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $vulkanVerified = [bool]$probe.Available -and [bool]$probe.Vulkan
            $gpuName = [string]$probe.Gpu
        } catch { }
    }
    if ($hasMagick -and $hasAiFiles -and $vulkanVerified) { return "本地引擎就绪：保守清晰 + AI（$gpuName / Vulkan）" }
    if ($hasMagick -and -not $hasAiFiles) { return '保守清晰可用；AI 引擎或模型不完整' }
    if ($hasMagick) { return '保守清晰可用；AI Vulkan 尚未验证' }
    return '本地图像处理组件尚未安装完整'
}

function Write-DesktopOrganizerLog {
    param([string]$Message)

    $entry = '[{0}] {1}' -f [DateTime]::Now.ToString('HH:mm:ss'), $Message
    $script:organizerLog.Insert(0, $entry)
    while ($script:organizerLog.Count -gt 200) { $script:organizerLog.RemoveAt($script:organizerLog.Count - 1) }
    if ($script:organizerDialogLogList -and -not $script:organizerDialogLogList.IsDisposed) {
        $script:organizerDialogLogList.Items.Insert(0, $entry)
        while ($script:organizerDialogLogList.Items.Count -gt 200) {
            $script:organizerDialogLogList.Items.RemoveAt($script:organizerDialogLogList.Items.Count - 1)
        }
    }
}

function Invoke-DesktopProductOrganizationUi {
    param([ValidateSet('left','center','right','all')][string]$Scope = 'left')

    $script:desktopOrganizeScope = $Scope
    $scopeLabel = @{left='屏幕左侧';center='屏幕中间';right='屏幕右侧';all='全局'}[$Scope]
    $positions = if ($Scope -eq 'all') { @() } else { @(Get-DesktopIconPositions) }
    $screenBounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $result = Invoke-DesktopProductOrganization -DesktopPath $defaultDesktopPath -HistoryPath $script:desktopProductHistoryPath -Scope $Scope -IconPositions $positions -ScreenBounds $screenBounds
    $message = "桌面成品整理完成（$scopeLabel）：编号 $($result.Code)，共移动 $($result.MovedCount) 个文件；成品图 $($result.NamedImageCount) 张，素材 $($result.MaterialImageCount) 张。"
    if ($result.Errors.Count) { $message += " 另有 $($result.Errors.Count) 个文件失败，请查看记录。" }
    Write-DesktopOrganizerLog $message
    foreach ($item in $result.Errors) { Write-DesktopOrganizerLog "整理失败：$item" }
    return $result
}

function Undo-DesktopProductOrganizationUi {
    param([Parameter(Mandatory)][string]$RecordId)

    $result = Undo-DesktopProductOrganization -HistoryPath $script:desktopProductHistoryPath -RecordId $RecordId
    $message = "已按记录恢复桌面整理：$($result.UndoneCount) 个文件已放回桌面。"
    if ($result.Errors.Count) { $message += " 另有 $($result.Errors.Count) 个文件未能撤回，请查看记录。" }
    Write-DesktopOrganizerLog $message
    foreach ($item in $result.Errors) { Write-DesktopOrganizerLog "撤回失败：$item" }
    return $result
}

function Set-RoundedControlRegion {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius
    )

    if (-not $Control -or $Control.IsDisposed -or $Control.Width -le 0 -or $Control.Height -le 0) { return }
    $diameter = [Math]::Max(2, [Math]::Min($Radius * 2, [Math]::Min($Control.Width, $Control.Height)))
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    try {
        $bounds = [System.Drawing.Rectangle]::new(0, 0, $Control.Width, $Control.Height)
        $path.AddArc($bounds.Left, $bounds.Top, $diameter, $diameter, 180, 90)
        $path.AddArc($bounds.Right - $diameter, $bounds.Top, $diameter, $diameter, 270, 90)
        $path.AddArc($bounds.Right - $diameter, $bounds.Bottom - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc($bounds.Left, $bounds.Bottom - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        $oldRegion = $Control.Region
        $Control.Region = [System.Drawing.Region]::new($path)
        if ($oldRegion) { $oldRegion.Dispose() }
    }
    finally { $path.Dispose() }
}

function Save-SmokeControlScreenshot {
    param(
        [System.Windows.Forms.Control]$Control,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ($Control -is [OverlayPillForm]) {
        $Control.SavePreview($Path)
        return
    }
    $pendingControls = [System.Collections.Generic.Queue[System.Windows.Forms.Control]]::new()
    $pendingControls.Enqueue($Control)
    while ($pendingControls.Count -gt 0) {
        $currentControl = $pendingControls.Dequeue()
        [void]$currentControl.Handle
        foreach ($child in $currentControl.Controls) { $pendingControls.Enqueue($child) }
    }
    $Control.PerformLayout()
    $bitmap = [System.Drawing.Bitmap]::new($Control.ClientSize.Width, $Control.ClientSize.Height)
    try {
        $Control.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height))
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}

function Update-DynamicIslandContent {
    if (-not $script:dynamicIslandForm -or $script:dynamicIslandForm.IsDisposed) { return }

    $titleText = '桌面整理助手'
    $detailText = '文件夹自动监控尚未开启'
    $dotColor = [System.Drawing.ColorTranslator]::FromHtml('#6B7280')
    $glowMode = 'Off'

    if (-not [string]::IsNullOrWhiteSpace([string]$script:dynamicIslandOverrideTitle)) {
        $titleText = [string]$script:dynamicIslandOverrideTitle
        $detailText = [string]$script:dynamicIslandOverrideDetail
        $dotColor = [System.Drawing.ColorTranslator]::FromHtml('#35C98B')
        $glowMode = 'Complete'
    }
    elseif ($script:organizerWorkerJob) {
        $projectName = [System.IO.Path]::GetFileName([string]$script:organizerWorkerJob.FolderPath)
        $titleText = '正在整理文件夹'
        $detailText = if ([string]::IsNullOrWhiteSpace($projectName)) { '正在移动并归类源文件' } else { $projectName }
        $dotColor = [System.Drawing.ColorTranslator]::FromHtml('#35C98B')
        $glowMode = 'Processing'
    }
    elseif ($script:organizerPending.Count -gt 0) {
        $pendingPath = @($script:organizerPending.Keys) | Select-Object -First 1
        $projectName = [System.IO.Path]::GetFileName([string]$pendingPath)
        $pendingCount = $script:organizerPending.Count
        $titleText = if ($pendingCount -gt 1) { "批量整理队列 · $pendingCount 个文件夹" } else { '发现新的下载文件夹' }
        $detailText = if ([string]::IsNullOrWhiteSpace($projectName)) { '等待下载完成' } else { "下一项：$projectName" }
        $dotColor = [System.Drawing.ColorTranslator]::FromHtml('#FFB547')
        $glowMode = 'Waiting'
    }
    elseif ($script:organizerEnabled -and $script:organizerWatcher) {
        $titleText = '桌面整理助手'
        $detailText = '正在监控钉钉下载文件夹'
        $dotColor = [System.Drawing.ColorTranslator]::FromHtml('#35C98B')
        $glowMode = 'Monitoring'
    }

    $script:dynamicIslandForm.SetContent($titleText, $detailText, $dotColor, $glowMode)
}

function Show-DynamicIsland {
    if (-not $script:dynamicIslandEnabled) { return }
    if ($script:dynamicIslandForm -and -not $script:dynamicIslandForm.IsDisposed) {
        Update-DynamicIslandContent
        return
    }

    $island = [OverlayPillForm]::new()
    $island.Text = '桌面整理助手灵动岛'
    $island.FormBorderStyle = 'None'
    $island.ShowInTaskbar = $false
    $island.TopMost = $true
    $island.StartPosition = 'Manual'
    $island.AutoScaleMode = 'None'

    $targetScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    try {
        if ($form -and $form.IsHandleCreated) { $targetScreen = [System.Windows.Forms.Screen]::FromControl($form) }
    } catch { }
    $workingArea = $targetScreen.WorkingArea
    # 以 394 x 94 为基准，按用户要求整体放大 20%。
    $layoutScale = 1.2
    $islandWidth = [Math]::Round(394 * $layoutScale)
    $islandHeight = [Math]::Round(94 * $layoutScale)
    $island.ConfigureLayoutScale([single]$layoutScale)
    $island.ClientSize = [System.Drawing.Size]::new($islandWidth, $islandHeight)
    $island.Location = [System.Drawing.Point]::new(
        [int]($workingArea.Left + (($workingArea.Width - $island.Width) / 2)),
        [int]($workingArea.Top + [Math]::Max(9, [Math]::Round(12 * $layoutScale)))
    )

    $script:dynamicIslandForm = $island
    Update-DynamicIslandContent
    $island.Show()
}

function Hide-DynamicIsland {
    if ($script:dynamicIslandResetTimer) { $script:dynamicIslandResetTimer.Stop() }
    $script:dynamicIslandOverrideTitle = $null
    $script:dynamicIslandOverrideDetail = $null
    if ($script:dynamicIslandForm) {
        try {
            if (-not $script:dynamicIslandForm.IsDisposed) {
                $script:dynamicIslandForm.Close()
                $script:dynamicIslandForm.Dispose()
            }
        } catch { }
    }
    $script:dynamicIslandForm = $null
    $script:dynamicIslandTitleLabel = $null
    $script:dynamicIslandDetailLabel = $null
    $script:dynamicIslandStatusDot = $null
}

function Set-DynamicIslandTemporaryMessage {
    param(
        [string]$Title,
        [string]$Detail,
        [int]$DurationMilliseconds = 4200
    )

    if (-not $script:dynamicIslandEnabled) { return }
    $script:dynamicIslandOverrideTitle = $Title
    $script:dynamicIslandOverrideDetail = $Detail
    Show-DynamicIsland
    Update-DynamicIslandContent
    if (-not $script:dynamicIslandResetTimer) {
        $script:dynamicIslandResetTimer = [System.Windows.Forms.Timer]::new()
        $script:dynamicIslandResetTimer.Add_Tick({
            $script:dynamicIslandResetTimer.Stop()
            $script:dynamicIslandOverrideTitle = $null
            $script:dynamicIslandOverrideDetail = $null
            Update-DynamicIslandContent
        })
    }
    $script:dynamicIslandResetTimer.Stop()
    $script:dynamicIslandResetTimer.Interval = [Math]::Max(500, $DurationMilliseconds)
    $script:dynamicIslandResetTimer.Start()
}

function Update-DesktopOrganizerUi {
    $organizerButton.Text = ''
    if ($script:activePage -eq 'Organizer') {
        $organizerButton.Image = $organizerIconSelected
        $organizerButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#74A7FF')
        $organizerButton.ForeColor = [System.Drawing.Color]::White
        $organizerToolTip.SetToolTip($organizerButton, '钉钉下载文件夹自动整理（当前页面）')
    } elseif ($script:organizerEnabled -and $script:organizerWatcher) {
        $organizerButton.Image = $organizerIconActive
        $organizerButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#DDF7EC')
        $organizerButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#087A55')
        $organizerToolTip.SetToolTip($organizerButton, '钉钉下载文件夹自动整理（监控中）')
    } else {
        $organizerButton.Image = $organizerIconDefault
        $organizerButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EEF2F8')
        $organizerButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#7890B3')
        $organizerToolTip.SetToolTip($organizerButton, '钉钉下载文件夹自动整理')
    }

    if ($script:organizerDialogStatusLabel -and -not $script:organizerDialogStatusLabel.IsDisposed) {
        if ($script:organizerEnabled -and $script:organizerWatcher) {
            $script:organizerDialogStatusLabel.Text = "仅监控钉钉目录：$($script:organizerPath)"
            $script:organizerDialogStatusLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#087A55')
            $script:organizerDialogStartButton.Text = '停止自动监控'
            $script:organizerDialogStartButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FBE4E4')
            $script:organizerDialogStartButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#9B2C2C')
            $script:organizerDialogPathBox.ReadOnly = $true
            $script:organizerDialogBrowseButton.Enabled = $false
        } else {
            $script:organizerDialogStatusLabel.Text = '尚未开启监控；桌面其他来源的文件不会被整理'
            $script:organizerDialogStatusLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#687086')
            $script:organizerDialogStartButton.Text = '开始自动监控'
            $script:organizerDialogStartButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#17A673')
            $script:organizerDialogStartButton.ForeColor = [System.Drawing.Color]::White
            $script:organizerDialogPathBox.ReadOnly = $false
            $script:organizerDialogBrowseButton.Enabled = $true
        }
    }
    Update-DynamicIslandContent
}

function Add-DesktopOrganizerPending {
    param([string]$Path, [switch]$Manual, [switch]$SilentCompletion)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $parentPath = [System.IO.Path]::GetFullPath((Split-Path -Parent $fullPath)).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $monitorPath = [System.IO.Path]::GetFullPath($script:organizerPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if (-not $Manual -and -not [string]::Equals($parentPath, $monitorPath, [System.StringComparison]::OrdinalIgnoreCase)) { return }
        if ($Manual) { [void]$script:organizerProcessed.Remove($fullPath) }
        if ($script:organizerProcessed.Contains($fullPath)) { return }
        if ($script:organizerPending.ContainsKey($fullPath)) {
            if ($Manual) {
                $script:organizerPending[$fullPath].Manual = $true
                if (-not $SilentCompletion) { $script:organizerPending[$fullPath].NotifyOnComplete = $true }
                $script:organizerPending[$fullPath].LastChangedUtc = [DateTime]::UtcNow.AddSeconds(-$script:organizerMinimumAgeSeconds - 1)
            }
            return
        }

        $contentWatcher = [System.IO.FileSystemWatcher]::new($fullPath)
        $contentWatcher.Filter = '*'
        $contentWatcher.IncludeSubdirectories = $true
        $contentWatcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::DirectoryName -bor [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
        $contentWatcher.SynchronizingObject = $form
        $activityHandler = {
            param($sender, $eventArgs)
            $watchedPath = [System.IO.Path]::GetFullPath([string]$sender.Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            if ($script:organizerPending.ContainsKey($watchedPath)) {
                $script:organizerPending[$watchedPath].LastChangedUtc = [DateTime]::UtcNow
            }
        }
        $contentWatcher.Add_Created($activityHandler)
        $contentWatcher.Add_Changed($activityHandler)
        $contentWatcher.Add_Deleted($activityHandler)
        $contentWatcher.Add_Renamed($activityHandler)
        $contentWatcher.Add_Error($activityHandler)
        $script:organizerPending[$fullPath] = [PSCustomObject]@{
            AddedUtc = [DateTime]::UtcNow
            LastChangedUtc = if ($Manual) { [DateTime]::UtcNow.AddSeconds(-$script:organizerMinimumAgeSeconds - 1) } else { [DateTime]::UtcNow }
            LastError = ''
            Manual = [bool]$Manual
            NotifyOnComplete = [bool]($Manual -and -not $SilentCompletion)
            ContentWatcher = $contentWatcher
        }
        # Check the short quiet window promptly while work is pending; return to
        # the low-frequency idle poll after the queue drains.
        $script:organizerTimer.Interval = $script:organizerActivePollMilliseconds
        $contentWatcher.EnableRaisingEvents = $true
        if ($Manual) {
            $script:organizerTimer.Start()
            Write-DesktopOrganizerLog "已加入后台整理：$([System.IO.Path]::GetFileName($fullPath))"
        }
        else { Write-DesktopOrganizerLog "发现新文件夹，等待下载稳定：$([System.IO.Path]::GetFileName($fullPath))" }
        Update-DynamicIslandContent
    }
    catch {
        Write-DesktopOrganizerLog ('无法加入待整理队列：' + $_.Exception.Message)
    }
}

function Remove-DesktopOrganizerPending {
    param([string]$Path)

    if (-not $script:organizerPending.ContainsKey($Path)) { return }
    $pending = $script:organizerPending[$Path]
    if ($pending.ContentWatcher) {
        try { $pending.ContentWatcher.EnableRaisingEvents = $false } catch { }
        try { $pending.ContentWatcher.Dispose() } catch { }
    }
    [void]$script:organizerPending.Remove($Path)
}

function Stop-DesktopOrganizer {
    param([switch]$PreserveEnabledPreference)

    $wasEnabled = $script:organizerEnabled
    if ($script:organizerTimer) {
        $script:organizerTimer.Stop()
        $script:organizerTimer.Interval = $script:organizerIdlePollMilliseconds
    }
    if ($script:organizerWatcher) {
        try { $script:organizerWatcher.EnableRaisingEvents = $false } catch { }
        try { $script:organizerWatcher.Dispose() } catch { }
        $script:organizerWatcher = $null
    }
    if ($script:organizerWorkerProcess) {
        try { if (-not $script:organizerWorkerProcess.HasExited) { $script:organizerWorkerProcess.Kill($true) } } catch { }
        try { $script:organizerWorkerProcess.Dispose() } catch { }
        $script:organizerWorkerProcess = $null
    }
    if ($script:organizerWorkerJob) {
        Remove-JobTemporaryDirectory $script:organizerWorkerJob.Directory
        $script:organizerWorkerJob = $null
    }
    foreach ($pendingPath in @($script:organizerPending.Keys)) { Remove-DesktopOrganizerPending $pendingPath }
    $script:organizerProcessed.Clear()
    if (-not $PreserveEnabledPreference) { $script:organizerEnabled = $false }
    else { $script:organizerEnabled = $wasEnabled }
    Update-DesktopOrganizerUi
    if (-not $PreserveEnabledPreference) {
        Write-DesktopOrganizerLog '已停止钉钉下载目录监控。'
        Save-AppState
    }
}

function Start-DesktopOrganizer {
    param([string]$Path, [switch]$Quiet)

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw '请选择钉钉专用下载目录。' }
        $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if (Test-IsDesktopRootPath -Path $normalizedPath -DesktopPath $defaultDesktopPath) {
            throw '不能直接监控桌面根目录，否则其他软件的下载也会被整理。请使用桌面中的“钉钉下载”专用文件夹，并在钉钉中把下载位置设为该目录。'
        }
        if (-not (Test-Path -LiteralPath $normalizedPath -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($normalizedPath)
        }

        if ($script:organizerWatcher -or $script:organizerWorkerProcess -or $script:organizerPending.Count -gt 0) { Stop-DesktopOrganizer -PreserveEnabledPreference }
        $script:organizerPath = $normalizedPath
        $script:organizerPending.Clear()
        $script:organizerProcessed.Clear()

        $watcher = [System.IO.FileSystemWatcher]::new($normalizedPath)
        $watcher.Filter = '*'
        $watcher.IncludeSubdirectories = $false
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::DirectoryName
        $watcher.SynchronizingObject = $form
        $watcher.Add_Created({
            param($sender, $eventArgs)
            Add-DesktopOrganizerPending ([string]$eventArgs.FullPath)
        })
        $watcher.Add_Renamed({
            param($sender, $eventArgs)
            Add-DesktopOrganizerPending ([string]$eventArgs.FullPath)
        })
        $watcher.Add_Error({
            param($sender, $eventArgs)
            Write-DesktopOrganizerLog '监控事件过多或发生异常；仍会继续监控后续文件夹。'
        })
        $script:organizerWatcher = $watcher
        $script:organizerEnabled = $true
        $watcher.EnableRaisingEvents = $true
        # Watch first, then reconcile folders downloaded while the app was closed.
        # Use the normal queue so downloads still wait for stability and duplicates are ignored.
        foreach ($folder in Get-ChildItem -LiteralPath $normalizedPath -Directory -Force -ErrorAction Stop) {
            Add-DesktopOrganizerPending -Path $folder.FullName
        }
        $script:organizerTimer.Start()
        Write-DesktopOrganizerLog "已开始仅监控钉钉下载目录：$normalizedPath"
        Update-DesktopOrganizerUi
        Save-AppState
        return $true
    }
    catch {
        $script:organizerEnabled = $false
        if ($script:organizerWatcher) {
            try { $script:organizerWatcher.Dispose() } catch { }
            $script:organizerWatcher = $null
        }
        Update-DesktopOrganizerUi
        Write-DesktopOrganizerLog ('启动监控失败：' + $_.Exception.Message)
        if (-not $Quiet) {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法启动钉钉下载自动整理', 'OK', 'Warning') | Out-Null
        }
        return $false
    }
}

function Open-SpreadsheetFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "表格不存在：$Path" }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($startInfo)
    if ($script:organizerSpreadsheetScreenEnabled) {
        $screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object DeviceName)
        if ($screens.Count -gt 0) {
            $screenIndex = [Math]::Max(0, [Math]::Min($script:organizerSpreadsheetScreenIndex, $screens.Count - 1))
            if ($script:spreadsheetWindowMoveJobs.Count -eq 0) { $script:spreadsheetWindowMoveHandles.Clear() }
            $script:spreadsheetWindowMoveJobs.Add([PSCustomObject]@{
                Title = [System.IO.Path]::GetFileNameWithoutExtension($Path)
                ScreenIndex = $screenIndex
                StartedAtUtc = [DateTime]::UtcNow
            })
            if ($script:spreadsheetWindowMoveTimer) { $script:spreadsheetWindowMoveTimer.Start() }
        }
    }
}

function Move-PendingSpreadsheetWindows {
    if ($script:spreadsheetWindowMoveJobs.Count -eq 0) {
        if ($script:spreadsheetWindowMoveTimer) { $script:spreadsheetWindowMoveTimer.Stop() }
        return
    }
    $screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object DeviceName)
    for ($index = $script:spreadsheetWindowMoveJobs.Count - 1; $index -ge 0; $index--) {
        $job = $script:spreadsheetWindowMoveJobs[$index]
        $expired = ([DateTime]::UtcNow - [DateTime]$job.StartedAtUtc).TotalSeconds -ge 10
        $window = @([SpreadsheetWindowMover]::FindVisibleWindows([string]$job.Title) | Where-Object { -not $script:spreadsheetWindowMoveHandles.Contains($_.ToInt64()) } | Select-Object -First 1)
        $window = if ($window.Count -gt 0) { [IntPtr]$window[0] } else { [IntPtr]::Zero }
        if ($window -ne [IntPtr]::Zero -and $screens.Count -gt 0) {
            $screenIndex = [Math]::Max(0, [Math]::Min([int]$job.ScreenIndex, $screens.Count - 1))
            if ([SpreadsheetWindowMover]::MoveToWorkingArea($window, $screens[$screenIndex].WorkingArea)) {
                [void]$script:spreadsheetWindowMoveHandles.Add($window.ToInt64())
                Write-DesktopOrganizerLog "已将表格移到第 $($screenIndex + 1) 个屏幕。"
                $script:spreadsheetWindowMoveJobs.RemoveAt($index)
                continue
            }
        }
        if ($expired) {
            Write-DesktopOrganizerLog "未能定位表格窗口，请手动移动到目标屏幕：$($job.Title)"
            $script:spreadsheetWindowMoveJobs.RemoveAt($index)
        }
    }
    if ($script:spreadsheetWindowMoveJobs.Count -eq 0 -and $script:spreadsheetWindowMoveTimer) {
        $script:spreadsheetWindowMoveTimer.Stop()
        $script:spreadsheetWindowMoveHandles.Clear()
    }
}

function Invoke-DesktopOrganizerQueue {
    if ($script:organizerQueueRunning) { return }
    $script:organizerQueueRunning = $true
    try {
    if ($script:organizerWorkerProcess) {
        if (-not $script:organizerWorkerProcess.HasExited) { return }
        $script:organizerTimer.Interval = $script:organizerIdlePollMilliseconds
        $jobState = $script:organizerWorkerJob
        try {
            $script:organizerWorkerProcess.WaitForExit()
            $script:organizerWorkerProcess.Dispose()
            $script:organizerWorkerProcess = $null
            if (-not (Test-Path -LiteralPath $jobState.ResultPath -PathType Leaf)) { throw '后台整理进程没有返回结果。' }
            $result = Get-Content -LiteralPath $jobState.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $path = [string]$result.FolderPath
            if ([bool]$result.Success) {
                $pendingRecord = if ($script:organizerPending.ContainsKey($path)) { $script:organizerPending[$path] } else { $null }
                $notifyOnComplete = $pendingRecord -and [bool]$pendingRecord.NotifyOnComplete
                $isAutomaticDownload = $pendingRecord -and -not [bool]$pendingRecord.Manual
                Remove-DesktopOrganizerPending $path
                $finalProjectPath = $path
                if ($isAutomaticDownload) {
                    try {
                        $finalProjectPath = Move-OrganizedProjectFolder -Path $path -DestinationDirectory $defaultDesktopPath
                        Write-DesktopOrganizerLog "已自动移到桌面：$([System.IO.Path]::GetFileName($finalProjectPath))"
                    }
                    catch {
                        Write-DesktopOrganizerLog "文件夹已整理，但移到桌面失败：$($_.Exception.Message)"
                    }
                }
                [void]$script:organizerProcessed.Add($finalProjectPath)
                Write-DesktopOrganizerLog "整理完成：$($result.ProjectName)，已移动 $($result.MovedCount) 项到【$($result.ProjectName) 源文件】"
                Set-DynamicIslandTemporaryMessage -Title '文件夹整理完成' -Detail "$($result.ProjectName) · 已移动 $($result.MovedCount) 项"
                $spreadsheetPath = $null
                if ($script:organizerOpenSpreadsheetEnabled -and $result.PSObject.Properties['SpreadsheetPath'] -and -not [string]::IsNullOrWhiteSpace([string]$result.SpreadsheetPath)) {
                    # The worker already selected the spreadsheet. Keep its relative path
                    # when the project moves, rather than scanning it again on the UI thread.
                    $originalRoot = [System.IO.Path]::GetFullPath($path).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
                    $workerSpreadsheetPath = [System.IO.Path]::GetFullPath([string]$result.SpreadsheetPath)
                    if ($workerSpreadsheetPath.StartsWith($originalRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $spreadsheetPath = Join-Path $finalProjectPath $workerSpreadsheetPath.Substring($originalRoot.Length)
                    }
                }
                if ($script:organizerOpenSpreadsheetEnabled -and -not [string]::IsNullOrWhiteSpace($spreadsheetPath) -and (Test-Path -LiteralPath $spreadsheetPath -PathType Leaf)) {
                    try {
                        Open-SpreadsheetFile -Path $spreadsheetPath
                        Write-DesktopOrganizerLog "已自动打开表格：$([System.IO.Path]::GetFileName($spreadsheetPath))"
                    }
                    catch {
                        Write-DesktopOrganizerLog "表格已整理完成，但自动打开失败：$($_.Exception.Message)"
                    }
                }
                if ($notifyOnComplete) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "整理完成。`n`n已创建：`n• $($result.ProjectName)`n• $($result.ProjectName) 源文件`n• 素材`n`n已把原第一层内容移入【$($result.ProjectName) 源文件】，共 $($result.MovedCount) 项。",
                        '桌面文件夹整理完成', 'OK', 'Information'
                    ) | Out-Null
                }
            } else {
                $errorText = [string]$result.Error
                if ($script:organizerPending.ContainsKey($path)) {
                    $pending = $script:organizerPending[$path]
                    if ($pending.LastError -ne $errorText) {
                        Write-DesktopOrganizerLog "文件夹尚未就绪，将在后台重试：$errorText"
                        $pending.LastError = $errorText
                    }
                    $pending.LastChangedUtc = [DateTime]::UtcNow
                } else {
                    Write-DesktopOrganizerLog "部分内容暂时无法移动，将自动重试：$errorText"
                }
            }
        }
        catch {
            Write-DesktopOrganizerLog ('后台整理失败，将自动重试：' + $_.Exception.Message)
            if ($jobState -and $script:organizerPending.ContainsKey([string]$jobState.FolderPath)) {
                $script:organizerPending[[string]$jobState.FolderPath].LastChangedUtc = [DateTime]::UtcNow
            }
        }
        finally {
            if ($script:organizerWorkerProcess) {
                try { $script:organizerWorkerProcess.Dispose() } catch { }
                $script:organizerWorkerProcess = $null
            }
            if ($jobState) { Remove-JobTemporaryDirectory $jobState.Directory }
            $script:organizerWorkerJob = $null
        }
    }

    foreach ($path in @($script:organizerPending.Keys)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Remove-DesktopOrganizerPending $path
            continue
        }
        $pending = $script:organizerPending[$path]
        if (([DateTime]::UtcNow - $pending.LastChangedUtc).TotalSeconds -lt $script:organizerMinimumAgeSeconds) { continue }
        $jobDirectory = $null
        try {
            $jobDirectory = Join-Path $script:taskTempRoot ('Organizer_' + [Guid]::NewGuid().ToString('N'))
            [void][System.IO.Directory]::CreateDirectory($jobDirectory)
            $jobPath = Join-Path $jobDirectory 'job.json'
            $resultPath = Join-Path $jobDirectory 'result.json'
            $job = [PSCustomObject]@{
                FolderPath = $path
                ModulePath = $script:folderOrganizerScriptPath
                ResultPath = $resultPath
            }
            [System.IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:powerShellPath
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $script:folderOrganizerWorkerScriptPath, '-JobPath', $jobPath)) { [void]$startInfo.ArgumentList.Add($argument) }
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw '无法启动后台整理进程。' }
            $script:organizerWorkerProcess = $process
            $script:organizerWorkerJob = [PSCustomObject]@{ FolderPath = $path; Directory = $jobDirectory; ResultPath = $resultPath }
            # Poll only the process handle while busy, so a finished project does not
            # leave the next queued project waiting for the two-second idle tick.
            $script:organizerTimer.Interval = $script:organizerActivePollMilliseconds
            Update-DynamicIslandContent
            break
        }
        catch {
            Write-DesktopOrganizerLog ('无法启动后台整理：' + $_.Exception.Message)
            if ($jobDirectory) { Remove-JobTemporaryDirectory $jobDirectory }
            $pending.LastChangedUtc = [DateTime]::UtcNow
        }
    }
    if (-not $script:organizerEnabled -and -not $script:organizerWorkerProcess -and $script:organizerPending.Count -eq 0) {
        $script:organizerTimer.Stop()
    }
    elseif (-not $script:organizerWorkerProcess) {
        $script:organizerTimer.Interval = if ($script:organizerPending.Count -gt 0) {
            $script:organizerActivePollMilliseconds
        } else {
            $script:organizerIdlePollMilliseconds
        }
    }
    Update-DynamicIslandContent
    }
    finally {
        $script:organizerQueueRunning = $false
    }
}

function Invoke-ManualProjectFolderOrganization {
    param([string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ([string]::Equals($fullPath, [System.IO.Path]::GetFullPath($script:organizerPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw '请选择桌面中的项目文件夹，不能直接选择桌面根目录。'
        }
        Add-DesktopOrganizerPending -Path $fullPath -Manual
        Invoke-DesktopOrganizerQueue
    }
    catch {
        Write-DesktopOrganizerLog ('手动整理失败：' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法整理文件夹', 'OK', 'Warning') | Out-Null
    }
}

function Add-OrganizerFoldersBatch {
    param([string[]]$Paths)

    $validPaths = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        try {
            $fullPath = [System.IO.Path]::GetFullPath([string]$candidate).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            $monitorRoot = [System.IO.Path]::GetFullPath($script:organizerPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            if ([string]::Equals($fullPath, $monitorRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($seen.Add($fullPath)) { $validPaths.Add($fullPath) }
        } catch { }
    }

    if ($validPaths.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('没有找到可整理的项目文件夹。请拖入一个或多个项目文件夹，不能直接拖入监控根目录。', '批量整理', 'OK', 'Information') | Out-Null
        return
    }

    $isBatch = $validPaths.Count -gt 1
    $beforeCount = $script:organizerPending.Count
    foreach ($folderPath in $validPaths) {
        Add-DesktopOrganizerPending -Path $folderPath -Manual -SilentCompletion:$isBatch
    }
    $addedCount = [Math]::Max(0, $script:organizerPending.Count - $beforeCount)
    if ($isBatch) {
        Write-DesktopOrganizerLog "批量任务已接收：选择 $($validPaths.Count) 个文件夹，新加入队列 $addedCount 个。"
        Set-DynamicIslandTemporaryMessage -Title '批量文件夹已加入' -Detail "$($validPaths.Count) 个文件夹将在后台逐个整理"
    }
    Invoke-DesktopOrganizerQueue
}

function Add-SpreadsheetFoldersBatch {
    param([string[]]$Paths)

    $knownFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($queued in $script:spreadsheetFolderQueue) { [void]$knownFolders.Add([string]$queued.FolderPath) }
    $addedCount = 0
    foreach ($candidate in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        try {
            $fullPath = [System.IO.Path]::GetFullPath([string]$candidate).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            if (-not $knownFolders.Add($fullPath)) { continue }
            $spreadsheetPath = Get-ProjectSpreadsheetPathForFolder -Path $fullPath
            $entry = [PSCustomObject]@{
                FolderPath = $fullPath
                SpreadsheetPath = $spreadsheetPath
                Item = $null
            }
            $item = [System.Windows.Forms.ListViewItem]::new([System.IO.Path]::GetFileName($fullPath))
            [void]$item.SubItems.Add($(if ([string]::IsNullOrWhiteSpace([string]$spreadsheetPath)) { '—' } else { [System.IO.Path]::GetFileName([string]$spreadsheetPath) }))
            [void]$item.SubItems.Add($(if ([string]::IsNullOrWhiteSpace([string]$spreadsheetPath)) { '未找到表格' } else { '已找到' }))
            $item.ToolTipText = if ([string]::IsNullOrWhiteSpace([string]$spreadsheetPath)) { $fullPath } else { [string]$spreadsheetPath }
            $entry.Item = $item
            $script:spreadsheetFolderQueue.Add($entry)
            [void]$spreadsheetList.Items.Add($item)
            $addedCount++
        }
        catch { }
    }
    $foundCount = @($script:spreadsheetFolderQueue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SpreadsheetPath) }).Count
    $spreadsheetStatus.Text = "已添加 $($script:spreadsheetFolderQueue.Count) 个文件夹，找到 $foundCount 个表格"
    if ($addedCount -eq 0 -and $script:spreadsheetFolderQueue.Count -eq 0) { $spreadsheetStatus.Text = '没有找到可加入的项目文件夹' }
}

function Clear-SpreadsheetFolderQueue {
    $script:spreadsheetFolderQueue.Clear()
    $spreadsheetList.Items.Clear()
    $spreadsheetStatus.Text = '尚未添加文件夹'
}

function Open-QueuedSpreadsheets {
    $openedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $openedCount = 0
    $failedCount = 0
    foreach ($entry in $script:spreadsheetFolderQueue) {
        $spreadsheetPath = [string]$entry.SpreadsheetPath
        if ([string]::IsNullOrWhiteSpace($spreadsheetPath)) { continue }
        if (-not $openedPaths.Add($spreadsheetPath)) {
            $entry.Item.SubItems[2].Text = '已跳过重复表格'
            continue
        }
        try {
            Open-SpreadsheetFile -Path $spreadsheetPath
            $entry.Item.SubItems[2].Text = '已打开'
            $entry.Item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#14855F')
            $openedCount++
        }
        catch {
            $entry.Item.SubItems[2].Text = '打开失败'
            $entry.Item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#B42318')
            $failedCount++
        }
    }
    $spreadsheetStatus.Text = if ($openedCount -eq 0 -and $failedCount -eq 0) {
        '列表中没有可打开的表格'
    } else {
        "已打开 $openedCount 个表格，失败 $failedCount 个"
    }
}

$spreadsheetAddParentButton.Add_Click({
    $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderDialog.Description = '选择父目录；其中全部第一层项目文件夹会加入待打开列表'
    $folderDialog.InitialDirectory = $script:organizerPath
    if ($folderDialog.ShowDialog($form) -eq 'OK') {
        $children = @(Get-ChildItem -LiteralPath $folderDialog.SelectedPath -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        Add-SpreadsheetFoldersBatch -Paths $children
    }
    $folderDialog.Dispose()
})
$spreadsheetClearButton.Add_Click({ Clear-SpreadsheetFolderQueue })
$spreadsheetOpenAllButton.Add_Click({ Open-QueuedSpreadsheets })

function Open-DesktopOrganizerPath {
    if (-not (Test-Path -LiteralPath $script:organizerPath -PathType Container)) { return }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:organizerPath
    $startInfo.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($startInfo)
}

function Show-DesktopOrganizerLegacyDialog {
    if ($script:organizerDialog -and -not $script:organizerDialog.IsDisposed) {
        $script:organizerDialog.Activate()
        return
    }

    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = '桌面下载文件夹自动整理'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [System.Drawing.Size]::new(760, 510)
    $dialog.MinimumSize = [System.Drawing.Size]::new(690, 500)
    $dialog.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F5F7FB')
    $dialog.Font = $form.Font
    $dialog.FormBorderStyle = 'Sizable'
    $script:organizerDialog = $dialog

    $dialogTitle = [System.Windows.Forms.Label]::new()
    $dialogTitle.Text = '钉钉下载文件夹 · 自动整理'
    $dialogTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
    $dialogTitle.AutoSize = $true
    $dialogTitle.Location = [System.Drawing.Point]::new(22, 18)
    $dialog.Controls.Add($dialogTitle)

    $description = [System.Windows.Forms.Label]::new()
    $description.Text = '仅处理开启监控后新出现的顶层文件夹。等待下载稳定后，创建“同名 / 同名 源文件 / 素材”，并把原第一层内容移入“源文件”。'
    $description.Location = [System.Drawing.Point]::new(25, 58)
    $description.Size = [System.Drawing.Size]::new(710, 44)
    $description.Anchor = 'Top,Left,Right'
    $description.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#4B556B')
    $dialog.Controls.Add($description)

    $pathLabel = [System.Windows.Forms.Label]::new()
    $pathLabel.Text = '钉钉目录：'
    $pathLabel.AutoSize = $true
    $pathLabel.Location = [System.Drawing.Point]::new(25, 115)
    $dialog.Controls.Add($pathLabel)

    $pathBox = [System.Windows.Forms.TextBox]::new()
    $pathBox.Text = $script:organizerPath
    $pathBox.Location = [System.Drawing.Point]::new(101, 111)
    $pathBox.Size = [System.Drawing.Size]::new(530, 28)
    $pathBox.Anchor = 'Top,Left,Right'
    $dialog.Controls.Add($pathBox)
    $script:organizerDialogPathBox = $pathBox

    $pathBrowseButton = New-Button '浏览…' 82 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
    $pathBrowseButton.Location = [System.Drawing.Point]::new(646, 108)
    $pathBrowseButton.Height = 32
    $pathBrowseButton.Anchor = 'Top,Right'
    $dialog.Controls.Add($pathBrowseButton)
    $script:organizerDialogBrowseButton = $pathBrowseButton

    $organizerStatus = [System.Windows.Forms.Label]::new()
    $organizerStatus.AutoSize = $true
    $organizerStatus.Location = [System.Drawing.Point]::new(25, 157)
    $dialog.Controls.Add($organizerStatus)
    $script:organizerDialogStatusLabel = $organizerStatus

    $startButton = New-Button '开始自动监控' 140 ([System.Drawing.ColorTranslator]::FromHtml('#17A673')) ([System.Drawing.Color]::White)
    $startButton.Location = [System.Drawing.Point]::new(25, 187)
    $dialog.Controls.Add($startButton)
    $script:organizerDialogStartButton = $startButton

    $manualButton = New-Button '整理已有文件夹…' 148 ([System.Drawing.ColorTranslator]::FromHtml('#2F6FED')) ([System.Drawing.Color]::White)
    $manualButton.Location = [System.Drawing.Point]::new(177, 187)
    $dialog.Controls.Add($manualButton)

    $openButton = New-Button '打开钉钉目录' 124 ([System.Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([System.Drawing.ColorTranslator]::FromHtml('#364158'))
    $openButton.Location = [System.Drawing.Point]::new(337, 187)
    $dialog.Controls.Add($openButton)

    $islandToggle = [PillToggleSwitch]::new()
    $islandToggle.Location = [System.Drawing.Point]::new(505, 190)
    $islandToggle.Anchor = 'Top,Right'
    $islandToggle.Checked = $script:dynamicIslandEnabled
    $dialog.Controls.Add($islandToggle)
    $script:organizerDialogIslandToggle = $islandToggle

    $islandLabel = [System.Windows.Forms.Label]::new()
    $islandLabel.Text = '显示灵动岛'
    $islandLabel.AutoSize = $true
    $islandLabel.Location = [System.Drawing.Point]::new(559, 187)
    $islandLabel.Anchor = 'Top,Right'
    $islandLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $dialog.Controls.Add($islandLabel)

    $islandDescription = [System.Windows.Forms.Label]::new()
    $islandDescription.Text = '屏幕顶部显示整理状态'
    $islandDescription.AutoSize = $true
    $islandDescription.Location = [System.Drawing.Point]::new(559, 209)
    $islandDescription.Anchor = 'Top,Right'
    $islandDescription.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#788196')
    $islandDescription.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 8, [System.Drawing.FontStyle]::Regular)
    $dialog.Controls.Add($islandDescription)

    $organizerToolTip.SetToolTip($islandToggle, '打开后，在屏幕顶部显示文件夹监控与整理进度。')
    $organizerToolTip.SetToolTip($islandLabel, '打开后，在屏幕顶部显示文件夹监控与整理进度。')

    $hint = [System.Windows.Forms.Label]::new()
    $hint.Text = '说明：仅处理钉钉专用下载目录中新出现的顶层文件夹，整理完成后自动移到桌面；桌面其他来源的文件不会被整理。同名内容会自动加序号，绝不覆盖。'
    $hint.Location = [System.Drawing.Point]::new(25, 239)
    $hint.Size = [System.Drawing.Size]::new(710, 48)
    $hint.Anchor = 'Top,Left,Right'
    $hint.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#A15C00')
    $dialog.Controls.Add($hint)

    $logTitle = [System.Windows.Forms.Label]::new()
    $logTitle.Text = '整理记录'
    $logTitle.AutoSize = $true
    $logTitle.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $logTitle.Location = [System.Drawing.Point]::new(25, 300)
    $dialog.Controls.Add($logTitle)

    $logList = [System.Windows.Forms.ListBox]::new()
    $logList.Location = [System.Drawing.Point]::new(25, 328)
    $logList.Size = [System.Drawing.Size]::new(710, 150)
    $logList.Anchor = 'Top,Bottom,Left,Right'
    $logList.HorizontalScrollbar = $true
    foreach ($entry in $script:organizerLog) { [void]$logList.Items.Add($entry) }
    $dialog.Controls.Add($logList)
    $script:organizerDialogLogList = $logList

    $pathBrowseButton.Add_Click({
        $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $folderDialog.Description = '选择要监控的新文件夹下载位置'
        $folderDialog.InitialDirectory = $pathBox.Text
        if ($folderDialog.ShowDialog($dialog) -eq 'OK') { $pathBox.Text = $folderDialog.SelectedPath }
        $folderDialog.Dispose()
    })
    $startButton.Add_Click({
        if ($script:organizerEnabled -and $script:organizerWatcher) {
            Stop-DesktopOrganizer
        } else {
            [void](Start-DesktopOrganizer -Path $pathBox.Text)
        }
    })
    $manualButton.Add_Click({
        $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $folderDialog.Description = '选择一个需要立即整理的项目文件夹'
        $folderDialog.InitialDirectory = $script:organizerPath
        if ($folderDialog.ShowDialog($dialog) -eq 'OK') {
            Invoke-ManualProjectFolderOrganization -Path $folderDialog.SelectedPath
        }
        $folderDialog.Dispose()
    })
    $openButton.Add_Click({ Open-DesktopOrganizerPath })
    $islandToggle.Add_CheckedChanged({
        param($sender, $eventArgs)
        $script:dynamicIslandEnabled = [bool]$sender.Checked
        if ($script:dynamicIslandEnabled) { Show-DynamicIsland } else { Hide-DynamicIsland }
        Save-AppState
    })
    $dialog.Add_FormClosed({
        $script:organizerDialogStatusLabel = $null
        $script:organizerDialogStartButton = $null
        $script:organizerDialogPathBox = $null
        $script:organizerDialogBrowseButton = $null
        $script:organizerDialogLogList = $null
        $script:organizerDialogIslandToggle = $null
        $script:organizerDialog = $null
    })

    Update-DesktopOrganizerUi
    if ($SmokeTest) {
        Save-SmokeControlScreenshot -Control $dialog -Path $SmokeTestOrganizerScreenshotPath
        $dialog.Dispose()
        $script:organizerDialogStatusLabel = $null
        $script:organizerDialogStartButton = $null
        $script:organizerDialogPathBox = $null
        $script:organizerDialogBrowseButton = $null
        $script:organizerDialogLogList = $null
        $script:organizerDialogIslandToggle = $null
        $script:organizerDialog = $null
        return
    }
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

# 保留旧函数名供已有调用使用，但行为改为主窗口内部页面切换。
function Show-DesktopOrganizerDialog {
    Show-DesktopOrganizerPage
    Show-OrganizerSubPage -Page 'Organizer'
    Update-Layout
    if ($SmokeTest -and -not [string]::IsNullOrWhiteSpace($SmokeTestOrganizerScreenshotPath)) {
        Save-SmokeControlScreenshot -Control $form -Path $SmokeTestOrganizerScreenshotPath
    }
}

$script:organizerTimer = [System.Windows.Forms.Timer]::new()
$script:organizerTimer.Interval = $script:organizerIdlePollMilliseconds
$script:organizerTimer.Add_Tick({ Invoke-DesktopOrganizerQueue })
$script:spreadsheetWindowMoveTimer = [System.Windows.Forms.Timer]::new()
$script:spreadsheetWindowMoveTimer.Interval = 250
$script:spreadsheetWindowMoveTimer.Add_Tick({ Move-PendingSpreadsheetWindows })
$script:stateSaveTimer = [System.Windows.Forms.Timer]::new()
$script:stateSaveTimer.Interval = 500
$script:stateSaveTimer.Add_Tick({
    $script:stateSaveTimer.Stop()
    if ($script:stateSaveDirty) { Save-AppState -Immediate }
})
$settings.Add_Resize({ Update-Layout })

function Add-ImageFiles {
    param([string[]]$Paths)

    $firstAddedPath = $null
    $duplicateCount = 0
    $previousSelectedItem = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$script:lastActivePath)) {
        $previousSelectedItem = $script:allItems | Where-Object { [string]$_.Tag -eq $script:lastActivePath } | Select-Object -First 1
    }
    if (-not $previousSelectedItem -and $list.SelectedItems.Count -gt 0) {
        $previousSelectedItem = $list.SelectedItems[0]
    }
    if (-not $previousSelectedItem) {
        $previousSelectedItem = $script:allItems | Where-Object Checked | Select-Object -Last 1
    }
    $newItems = [System.Collections.Generic.List[System.Windows.Forms.ListViewItem]]::new()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ([System.IO.Path]::GetExtension($path) -notmatch '^\.(png|jpe?g|jfif|webp|pdf|docx?|pptx?)$') { continue }
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if ($script:files.Contains($fullPath)) {
            $duplicateCount++
            if (-not $firstAddedPath) { $firstAddedPath = $fullPath }
            continue
        }

        try {
            # 只读取 PNG/JPEG/WebP 的文件头，不在拖放事件中解码整张大图。
            # 这样列表会立即出现，缩略预览交给独立后台进程生成。
            $imageWidth = 0
            $imageHeight = 0
            $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
            $dimensions = if ([ImageHeaderReader]::TryGetDimensions($fullPath, [ref]$imageWidth, [ref]$imageHeight)) {
                '{0} × {1}' -f $imageWidth, $imageHeight
            } elseif ($extension -eq '.pdf') {
                'PDF 文档'
            } elseif ($extension -in @('.doc', '.docx')) {
                'Word 文档'
            } elseif ($extension -in @('.ppt', '.pptx')) {
                'PPT 演示'
            } else {
                '待识别'
            }
            $fileInfo = [System.IO.FileInfo]::new($fullPath)
            $item = [System.Windows.Forms.ListViewItem]::new($fileInfo.Name)
            [void]$item.SubItems.Add($dimensions)
            [void]$item.SubItems.Add((Format-FileSize $fileInfo.Length))
            [void]$item.SubItems.Add('等待转换')
            $item.Tag = $fullPath
            $item.Name = [DateTime]::Now.ToString('o')
            $item.Checked = $true
            $script:allItems.Add($item)
            $newItems.Add($item)
            $script:files.Add($fullPath)
            if (-not $firstAddedPath) { $firstAddedPath = $fullPath }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("无法读取文件：`n$fullPath`n`n$($_.Exception.Message)", '读取失败', 'OK', 'Warning') | Out-Null
        }
    }

    # 成功添加新图片后，取消所有已完成旧任务的勾选。
    # 单张拖入仍额外取消上一张当前图片；批量拖入保留未完成旧任务的勾选状态。
    if (-not $script:isLoadingState -and $newItems.Count -gt 0) {
        $script:updatingChecks = $true
        try {
            foreach ($existingItem in $script:allItems) {
                if ($existingItem.SubItems.Count -gt 3 -and [string]$existingItem.SubItems[3].Text -eq '完成') {
                    $existingItem.Checked = $false
                }
            }
            if ($newItems.Count -eq 1 -and $previousSelectedItem -and $previousSelectedItem -ne $newItems[0]) {
                $previousSelectedItem.Checked = $false
                $newItems[0].Checked = $true
            }
        }
        finally { $script:updatingChecks = $false }
    }

    if ($newItems.Count -gt 0) {
        # 拖入时只把本次新增项追加到原生 ListView，不再清空并重建整份历史列表。
        # 历史越多时，这一处对“拖入后多久显示”影响越明显。
        $keyword = $searchBox.Text.Trim()
        $script:updatingChecks = $true
        $list.BeginUpdate()
        try {
            foreach ($newItem in $newItems) {
                if ([string]::IsNullOrWhiteSpace($keyword) -or $newItem.Text.IndexOf($keyword, [System.StringComparison]::CurrentCultureIgnoreCase) -ge 0) {
                    [void]$list.Items.Add($newItem)
                }
            }
        }
        finally {
            $list.EndUpdate()
            $script:updatingChecks = $false
        }
        Update-HorizontalScrollRange
        Update-VerticalScrollRange
    }

    if ($firstAddedPath) {
        $script:lastActivePath = $firstAddedPath
        # 无论当前搜索是否隐藏了旧项目，都只保留新拖入图片的高亮选择。
        foreach ($entry in $script:allItems) {
            $entry.Selected = $false
            $entry.Focused = $false
        }
        $addedItem = $list.Items | Where-Object { [string]$_.Tag -eq $firstAddedPath } | Select-Object -First 1
        if ($addedItem) {
            $addedItem.Selected = $true
            $addedItem.Focused = $true
            $addedItem.EnsureVisible()
            $list.Select()
        }
        Show-ImagePreview $firstAddedPath
    }
    Update-CheckedStatus
    if ($duplicateCount -gt 0) {
        $status.Text += "；已定位并跳过 $duplicateCount 个重复文件"
    }
    Save-AppState
}

function Apply-NameFilter {
    $keyword = $searchBox.Text.Trim()
    $script:updatingChecks = $true
    try {
        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            foreach ($item in $script:allItems) {
                if ([string]::IsNullOrWhiteSpace($keyword) -or $item.Text.IndexOf($keyword, [System.StringComparison]::CurrentCultureIgnoreCase) -ge 0) {
                    [void]$list.Items.Add($item)
                }
            }
        }
        finally { $list.EndUpdate() }
    }
    finally { $script:updatingChecks = $false }
    Update-HorizontalScrollRange
    Update-VerticalScrollRange
    Update-CheckedStatus
}

function Get-CheckedCount {
    $count = 0
    foreach ($item in $script:allItems) { if ($item.Checked) { $count++ } }
    return $count
}

function Update-CheckedStatus {
    if ($script:allItems.Count -eq 0) {
        $status.Text = '拖入图片、PDF、Word 或 PPT 文件，或点击“添加文件”'
        return
    }
    $checkedCount = Get-CheckedCount
    $matchText = if ($list.Items.Count -ne $script:allItems.Count) { "，搜索匹配 $($list.Items.Count) 项" } else { '' }
    $status.Text = "已勾选 $checkedCount / $($script:allItems.Count) 项$matchText"
    $script:updatingChecks = $true
    try { $selectAllCheck.Checked = ($checkedCount -eq $script:allItems.Count) }
    finally { $script:updatingChecks = $false }
}

function Set-PictureBoxImage {
    param([System.Windows.Forms.PictureBox]$PictureBox, [string]$Path)
    $oldImage = $PictureBox.Image
    $PictureBox.Image = $null
    if ($oldImage) { $oldImage.Dispose() }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $stream = [System.IO.MemoryStream]::new($bytes, $false)
    try {
        $source = [System.Drawing.Image]::FromStream($stream, $true, $true)
        try {
            $PictureBox.Image = [System.Drawing.Bitmap]::new($source)
            return [System.Drawing.Size]::new($source.Width, $source.Height)
        }
        finally { $source.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Stop-PreviewWorker {
    if ($script:previewRequestTimer) { $script:previewRequestTimer.Stop() }
    $script:pendingPreviewPath = $null
    if ($script:previewTimer) { $script:previewTimer.Stop() }
    if ($script:previewProcess) {
        try { if (-not $script:previewProcess.HasExited) { $script:previewProcess.Kill($true) } } catch { }
        try { $script:previewProcess.Dispose() } catch { }
        $script:previewProcess = $null
    }
    if ($script:previewJob) {
        Remove-JobTemporaryDirectory $script:previewJob.Directory
        $script:previewJob = $null
    }
}

function Start-ImagePreview {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Stop-PreviewWorker
        Set-PictureBoxImage $previewBox $null | Out-Null
        Set-PictureBoxImage $resultPreviewBox $null | Out-Null
        $script:displayedPreviewPath = $null
        $script:displayedResultPath = $null
        $previewInfo.Text = '选择一张图片查看预览'
        return
    }

    $resultSourcePath = if ($script:resultPaths.ContainsKey($Path)) { $script:resultPaths[$Path] } else { $null }
    if ($resultSourcePath -and [IO.Path]::GetExtension([string]$resultSourcePath).ToLowerInvariant() -notin @('.png', '.jpg', '.jpeg', '.jfif', '.webp')) {
        $resultSourcePath = $null
    }
    if ([string]$script:displayedPreviewPath -eq $Path -and [string]$script:displayedResultPath -eq [string]$resultSourcePath -and $previewBox.Image) {
        return
    }
    if ($script:previewProcess -and $script:previewJob -and [string]$script:previewJob.SourcePath -eq $Path -and -not $script:previewProcess.HasExited) {
        return
    }

    try {
        Stop-PreviewWorker
        Set-PictureBoxImage $previewBox $null | Out-Null
        Set-PictureBoxImage $resultPreviewBox $null | Out-Null
        $previewInfo.Text = "正在后台加载预览：$([System.IO.Path]::GetFileName($Path))"

        $jobDirectory = Join-Path $script:taskTempRoot ('Preview_' + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($jobDirectory)
        $originalPreviewPath = Join-Path $jobDirectory 'original-preview.png'
        $resultPreviewPath = Join-Path $jobDirectory 'result-preview.png'
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $isDirectPreview = [string]::IsNullOrWhiteSpace([string]$resultSourcePath)
        if ($isDirectPreview) {
            # 新拖入的原图直接交给 ImageMagick，省去每次预览额外启动 PowerShell 的延迟。
            $startInfo.FileName = $script:magickPath
            $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName($script:magickPath)
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @(
                $Path, '-auto-orient', '-print', '%w|%h', '-thumbnail', '1000x1000>',
                '-background', '#EEF2F8', '-alpha', 'background', '-strip', $originalPreviewPath
            )) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        } else {
            $jobPath = Join-Path $jobDirectory 'job.json'
            $responsePath = Join-Path $jobDirectory 'result.json'
            $job = [PSCustomObject]@{
                SourcePath = $Path
                ResultSourcePath = $resultSourcePath
                MagickPath = $script:magickPath
                MaxWidth = 1000
                MaxHeight = 1000
                OriginalPreviewPath = $originalPreviewPath
                ResultPreviewPath = $resultPreviewPath
                ResponsePath = $responsePath
            }
            [System.IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
            $startInfo.FileName = $script:powerShellPath
            foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $script:previewWorkerScriptPath, '-JobPath', $jobPath)) { [void]$startInfo.ArgumentList.Add($argument) }
        }
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw '无法启动后台预览进程。' }
        $outputTask = if ($isDirectPreview) { $process.StandardOutput.ReadToEndAsync() } else { $null }
        $errorTask = if ($isDirectPreview) { $process.StandardError.ReadToEndAsync() } else { $null }
        $script:previewProcess = $process
        $script:previewJob = [PSCustomObject]@{
            SourcePath = $Path
            ResultSourcePath = $resultSourcePath
            Directory = $jobDirectory
            ResponsePath = if ($isDirectPreview) { $null } else { $responsePath }
            OriginalPreviewPath = $originalPreviewPath
            Direct = $isDirectPreview
            OutputTask = $outputTask
            ErrorTask = $errorTask
        }
        $script:previewTimer.Start()
    }
    catch {
        $previewInfo.Text = '预览失败：' + $_.Exception.Message
    }
}

function Show-ImagePreview {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        if ($script:previewRequestTimer) { $script:previewRequestTimer.Stop() }
        $script:pendingPreviewPath = $null
        Start-ImagePreview $null
        return
    }
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.pdf', '.doc', '.docx', '.ppt', '.pptx')) {
        Stop-PreviewWorker
        Set-PictureBoxImage $previewBox $null | Out-Null
        Set-PictureBoxImage $resultPreviewBox $null | Out-Null
        $script:displayedPreviewPath = $null
        $script:displayedResultPath = $null
        $previewInfo.Text = "文档已加入队列：$([IO.Path]::GetFileName($Path))；转换后按页输出"
        return
    }
    [int]$layoutImageWidth = 0
    [int]$layoutImageHeight = 0
    if ([ImageHeaderReader]::TryGetDimensions($Path, [ref]$layoutImageWidth, [ref]$layoutImageHeight)) {
        Set-PreviewComparisonLayout -ImageWidth $layoutImageWidth -ImageHeight $layoutImageHeight
    }
    $script:pendingPreviewPath = $Path
    $previewInfo.Text = "正在后台加载预览：$([System.IO.Path]::GetFileName($Path))"
    $script:previewRequestTimer.Stop()
    $script:previewRequestTimer.Start()
}

$script:previewRequestTimer = [System.Windows.Forms.Timer]::new()
$script:previewRequestTimer.Interval = 10
$script:previewRequestTimer.Add_Tick({
    $script:previewRequestTimer.Stop()
    $requestedPath = $script:pendingPreviewPath
    $script:pendingPreviewPath = $null
    Start-ImagePreview $requestedPath
})

$script:previewTimer = [System.Windows.Forms.Timer]::new()
$script:previewTimer.Interval = 30
$script:previewTimer.Add_Tick({
    if (-not $script:previewProcess -or -not $script:previewJob -or -not $script:previewProcess.HasExited) { return }
    $jobState = $script:previewJob
    try {
        $script:previewTimer.Stop()
        $script:previewProcess.WaitForExit()
        $exitCode = $script:previewProcess.ExitCode
        $script:previewProcess.Dispose()
        $script:previewProcess = $null
        if ([bool]$jobState.Direct) {
            $output = $jobState.OutputTask.GetAwaiter().GetResult()
            $errorText = $jobState.ErrorTask.GetAwaiter().GetResult()
            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $jobState.OriginalPreviewPath -PathType Leaf)) {
                $message = ($errorText + "`n" + $output).Trim()
                if ([string]::IsNullOrWhiteSpace($message)) { $message = "预览引擎退出代码：$exitCode" }
                throw $message
            }
            $sizeParts = $output.Trim().Split('|')
            if ($sizeParts.Count -lt 2) { throw '无法读取图片尺寸。' }
            $result = [PSCustomObject]@{
                Success = $true
                SourcePath = [string]$jobState.SourcePath
                OriginalPreviewPath = [string]$jobState.OriginalPreviewPath
                OriginalWidth = [int]$sizeParts[0]
                OriginalHeight = [int]$sizeParts[1]
                ResultPreviewPath = $null
                ResultWidth = 0
                ResultHeight = 0
            }
        } else {
            if (-not (Test-Path -LiteralPath $jobState.ResponsePath -PathType Leaf)) { throw '后台预览没有返回结果。' }
            $result = Get-Content -LiteralPath $jobState.ResponsePath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if (-not [bool]$result.Success) { throw [string]$result.Error }
        if ([string]$script:lastActivePath -ne [string]$result.SourcePath) { return }

        Set-PreviewComparisonLayout -ImageWidth ([int]$result.OriginalWidth) -ImageHeight ([int]$result.OriginalHeight)
        Set-PictureBoxImage $previewBox ([string]$result.OriginalPreviewPath) | Out-Null
        $hasResult = -not [string]::IsNullOrWhiteSpace([string]$result.ResultPreviewPath) -and (Test-Path -LiteralPath ([string]$result.ResultPreviewPath) -PathType Leaf)
        if ($hasResult) { Set-PictureBoxImage $resultPreviewBox ([string]$result.ResultPreviewPath) | Out-Null }
        else { Set-PictureBoxImage $resultPreviewBox $null | Out-Null }
        $script:displayedPreviewPath = [string]$result.SourcePath
        $script:displayedResultPath = [string]$jobState.ResultSourcePath
        $previewInfo.Text = if ($hasResult) {
            "{0}：{1} × {2}  →  {3} × {4}" -f ([System.IO.Path]::GetFileName([string]$result.SourcePath)), [int]$result.OriginalWidth, [int]$result.OriginalHeight, [int]$result.ResultWidth, [int]$result.ResultHeight
        } else {
            "{0}`n{1} × {2}" -f ([System.IO.Path]::GetFileName([string]$result.SourcePath)), [int]$result.OriginalWidth, [int]$result.OriginalHeight
        }
        $listItem = $script:allItems | Where-Object { [string]$_.Tag -eq [string]$result.SourcePath } | Select-Object -First 1
        if ($listItem -and [string]$listItem.SubItems[1].Text -eq '待识别') {
            $listItem.SubItems[1].Text = '{0} × {1}' -f [int]$result.OriginalWidth, [int]$result.OriginalHeight
        }
    }
    catch {
        if ([string]$script:lastActivePath -eq [string]$jobState.SourcePath) {
            $previewInfo.Text = '预览失败：' + $_.Exception.Message
        }
    }
    finally {
        Remove-JobTemporaryDirectory $jobState.Directory
        $script:previewJob = $null
    }
})

$list.Add_SelectedIndexChanged({
    if ($list.SelectedItems.Count -gt 0) {
        $script:lastActivePath = [string]$list.SelectedItems[0].Tag
        Show-ImagePreview ([string]$list.SelectedItems[0].Tag)
    }
})

$list.Add_ItemChecked({
    if (-not $script:updatingChecks -and $form.IsHandleCreated -and -not $form.IsDisposed -and -not $form.Disposing) {
        try {
            $form.BeginInvoke([Action]{
                Update-CheckedStatus
                Save-AppState
            }) | Out-Null
        }
        catch [System.InvalidOperationException] {
            # 窗口正在创建或关闭时由 Shown/FormClosed 事件统一同步，避免无句柄 BeginInvoke。
        }
    }
})

$searchBox.Add_TextChanged({ Apply-NameFilter })

function Scroll-ListPage {
    param([int]$Direction)
    if ($list.Items.Count -eq 0) { return }
    $currentIndex = 0
    try {
        if ($list.TopItem) { $currentIndex = $list.TopItem.Index }
    } catch { }
    $pageSize = Get-VisibleListRowCount
    Set-ListTopIndex -Index ($currentIndex + ($Direction * $pageSize))
    $list.Focus()
}

function Scroll-ListRows {
    param(
        [int]$Direction,
        [int]$WheelSteps = 1
    )
    if ($list.Items.Count -eq 0 -or $Direction -eq 0) { return }
    $rowsPerStep = [System.Windows.Forms.SystemInformation]::MouseWheelScrollLines
    if ($rowsPerStep -lt 1 -or $rowsPerStep -gt 12) { $rowsPerStep = 3 }
    $currentIndex = 0
    try { if ($list.TopItem) { $currentIndex = $list.TopItem.Index } } catch { }
    Set-ListTopIndex -Index ($currentIndex + ($Direction * [Math]::Max(1, $WheelSteps) * $rowsPerStep))
}

$verticalWheelHandler = {
    param($sender, $eventArgs)
    if ($list.Items.Count -eq 0) { return }
    $wheelSteps = [Math]::Max(1, [Math]::Floor([Math]::Abs($eventArgs.Delta) / 120))
    $direction = if ($eventArgs.Delta -gt 0) { -1 } else { 1 }
    Scroll-ListRows -Direction $direction -WheelSteps $wheelSteps
    if ($eventArgs -is [System.Windows.Forms.HandledMouseEventArgs]) { $eventArgs.Handled = $true }
}

$verticalWheelTargets = @(
    $listPanel,
    $listHost,
    $contentSplit.Panel1,
    $contentSplit.Panel2,
    $previewLayout,
    $previewBox,
    $previewInfo
)
$list.Add_VerticalMouseWheel($verticalWheelHandler)
foreach ($wheelTarget in $verticalWheelTargets) {
    $wheelTarget.Add_MouseEnter({ $list.Focus() })
    $wheelTarget.Add_MouseWheel($verticalWheelHandler)
}

function Get-VisibleListRowCount {
    if ($list.Items.Count -eq 0) { return 1 }
    $rowHeight = 24
    $firstRowTop = 24
    try {
        $firstRowRectangle = $list.GetItemRect(0)
        if ($firstRowRectangle.Height -gt 0) { $rowHeight = $firstRowRectangle.Height }
        if ($firstRowRectangle.Top -gt 0) { $firstRowTop = $firstRowRectangle.Top }
    } catch { }
    return [Math]::Max(1, [Math]::Floor(($list.ClientSize.Height - $firstRowTop) / $rowHeight))
}

function Get-MaxListTopIndex {
    $visibleRows = Get-VisibleListRowCount
    return [Math]::Max(0, $list.Items.Count - $visibleRows)
}

function Sync-VerticalScrollValue {
    if ($script:syncingVerticalScroll) { return }
    $script:syncingVerticalScroll = $true
    try {
        if ($list.Items.Count -eq 0 -or -not $verticalScroll.Enabled) {
            if ($verticalScroll.Value -ne 0) { $verticalScroll.Value = 0 }
            return
        }
        $topIndex = 0
        try { if ($list.TopItem) { $topIndex = $list.TopItem.Index } } catch { }
        $effectiveMaximum = [Math]::Max(0, $verticalScroll.Maximum - $verticalScroll.LargeChange + 1)
        $targetValue = [Math]::Max($verticalScroll.Minimum, [Math]::Min($effectiveMaximum, $topIndex))
        if ($verticalScroll.Value -ne $targetValue) { $verticalScroll.Value = $targetValue }
    }
    finally { $script:syncingVerticalScroll = $false }
}

function Update-VerticalScrollRange {
    $visibleRows = Get-VisibleListRowCount
    $maximumTopIndex = [Math]::Max(0, $list.Items.Count - $visibleRows)
    $script:syncingVerticalScroll = $true
    try {
        $verticalScroll.Minimum = 0
        $verticalScroll.SmallChange = 1
        $verticalScroll.LargeChange = [Math]::Max(1, $visibleRows)
        $verticalScroll.Maximum = [Math]::Max(0, $maximumTopIndex + $verticalScroll.LargeChange - 1)
        $verticalScroll.Enabled = ($maximumTopIndex -gt 0)
        if (-not $verticalScroll.Enabled -and $verticalScroll.Value -ne 0) {
            $verticalScroll.Value = 0
        }
    }
    finally { $script:syncingVerticalScroll = $false }
    Sync-VerticalScrollValue
}

function Set-ListTopIndex {
    param([int]$Index)
    if ($list.Items.Count -eq 0) { return }
    $targetIndex = [Math]::Max(0, [Math]::Min((Get-MaxListTopIndex), $Index))
    try {
        $list.TopItem = $list.Items[$targetIndex]
    }
    catch {
        $list.Items[$targetIndex].EnsureVisible()
    }
    Sync-VerticalScrollValue
}

$verticalScroll.Add_Scroll({
    param($sender, $eventArgs)
    if (-not $script:syncingVerticalScroll) {
        Set-ListTopIndex -Index $eventArgs.NewValue
    }
})

$verticalScrollSyncTimer = [System.Windows.Forms.Timer]::new()
$verticalScrollSyncTimer.Interval = 150
$verticalScrollSyncTimer.Add_Tick({ Sync-VerticalScrollValue })

function Update-HorizontalScrollRange {
    $totalColumnWidth = 0
    foreach ($column in $list.Columns) { $totalColumnWidth += $column.Width }
    $overflow = [Math]::Max(0, $totalColumnWidth - $list.ClientSize.Width + 8)
    $largeChange = [Math]::Max(40, [Math]::Floor($list.ClientSize.Width / 2))
    $horizontalScroll.LargeChange = $largeChange
    $horizontalScroll.SmallChange = 24
    $horizontalScroll.Maximum = [Math]::Max($largeChange - 1, $overflow + $largeChange - 1)
    if ($horizontalScroll.Value -gt $overflow) { $horizontalScroll.Value = $overflow }
    $horizontalScroll.Enabled = ($overflow -gt 0)
}

$horizontalScroll.Add_Scroll({
    param($sender, $eventArgs)
    $delta = $eventArgs.NewValue - $eventArgs.OldValue
    if ($delta -ne 0) {
        [void][ListViewScroller]::SendMessage($list.Handle, [ListViewScroller]::LVM_SCROLL, [IntPtr]$delta, [IntPtr]::Zero)
    }
    $list.Focus()
})

$listPanel.Add_Resize({
    Update-HorizontalScrollRange
    Update-VerticalScrollRange
})
$list.Add_Resize({ Update-VerticalScrollRange })
$list.Add_ColumnWidthChanged({ Update-HorizontalScrollRange })

$scrollUpButton.Add_Click({
    Scroll-ListPage -Direction -1
})

$scrollDownButton.Add_Click({
    Scroll-ListPage -Direction 1
})

$scrollLeftButton.Add_Click({
    [void][ListViewScroller]::SendMessage($list.Handle, [ListViewScroller]::WM_HSCROLL, [IntPtr][ListViewScroller]::SB_PAGELEFT, [IntPtr]::Zero)
})

$scrollRightButton.Add_Click({
    [void][ListViewScroller]::SendMessage($list.Handle, [ListViewScroller]::WM_HSCROLL, [IntPtr][ListViewScroller]::SB_PAGERIGHT, [IntPtr]::Zero)
})

$list.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Space -and $list.SelectedItems.Count -gt 0) {
        $newState = -not $list.SelectedItems[0].Checked
        $script:updatingChecks = $true
        try {
            foreach ($selectedItem in $list.SelectedItems) { $selectedItem.Checked = $newState }
        }
        finally { $script:updatingChecks = $false }
        Update-CheckedStatus
        $eventArgs.SuppressKeyPress = $true
    }
})

$list.Add_MouseClick({
    param($sender, $eventArgs)
    $clickedItem = $list.GetItemAt($eventArgs.X, $eventArgs.Y)
    if ($clickedItem) { Show-ImagePreview ([string]$clickedItem.Tag) }
})

$previewButton.Add_Click({
    $item = if ($list.SelectedItems.Count -gt 0) {
        $list.SelectedItems[0]
    } elseif ($list.Items.Count -gt 0) {
        $list.Items[0]
    } else {
        $null
    }
    if ($item) {
        $item.Selected = $true
        $item.Focused = $true
        Show-ImagePreview ([string]$item.Tag)
    } else {
        [System.Windows.Forms.MessageBox]::Show('请先添加一张 PNG、JPG、JFIF 或 WebP 图片。', '预览', 'OK', 'Information') | Out-Null
    }
})

$selectAllCheck.Add_CheckedChanged({
    if ($script:updatingChecks) { return }
    $script:updatingChecks = $true
    try {
        foreach ($item in $script:allItems) { $item.Checked = $selectAllCheck.Checked }
    }
    finally { $script:updatingChecks = $false }
    Update-CheckedStatus
    Save-AppState
})

$invertButton.Add_Click({
    $script:updatingChecks = $true
    try {
        foreach ($item in $script:allItems) { $item.Checked = -not $item.Checked }
    }
    finally { $script:updatingChecks = $false }
    Update-CheckedStatus
    Save-AppState
})

$organizerButton.Add_Click({ Show-DesktopOrganizerDialog })

$addButton.Add_Click({
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = '选择图片、PDF、Word 或 PPT 文件'
    $dialog.Filter = '支持的文件|*.png;*.jpg;*.jpeg;*.jfif;*.webp;*.pdf;*.doc;*.docx;*.ppt;*.pptx|图片|*.png;*.jpg;*.jpeg;*.jfif;*.webp|PDF 文档|*.pdf|Word 文档|*.doc;*.docx|PowerPoint 演示|*.ppt;*.pptx'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog() -eq 'OK') { Add-ImageFiles $dialog.FileNames }
    $dialog.Dispose()
})

$clearButton.Add_Click({
    if (-not $script:isConverting) {
        $script:files.Clear()
        $script:allItems.Clear()
        $script:lastActivePath = $null
        $list.Items.Clear()
        Show-ImagePreview $null
        Update-CheckedStatus
        Save-AppState
    }
})

$sameFolder.Add_CheckedChanged({
    $outputBox.Enabled = -not $sameFolder.Checked
    $browseButton.Enabled = $true
    Save-AppState
})
$outputBox.Add_TextChanged({ Save-AppState })

$browseButton.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = '选择转换文件输出文件夹'
    if ($dialog.ShowDialog() -eq 'OK') {
        $outputBox.Text = $dialog.SelectedPath
        $sameFolder.Checked = $false
    }
    $dialog.Dispose()
})

$bgCombo.Add_SelectedIndexChanged({
    switch ($bgCombo.SelectedIndex) {
        0 { $script:backgroundColor = [System.Drawing.Color]::White }
        1 { $script:backgroundColor = [System.Drawing.Color]::Black }
        2 {
            $dialog = [System.Windows.Forms.ColorDialog]::new()
            $dialog.Color = $script:backgroundColor
            if ($dialog.ShowDialog() -eq 'OK') { $script:backgroundColor = $dialog.Color }
            $dialog.Dispose()
        }
    }
    $colorPreview.BackColor = $script:backgroundColor
    Save-AppState
})

$sizeCombo.Add_SelectedIndexChanged({ Update-EnhancementControls; Save-AppState })
$enhanceCombo.Add_SelectedIndexChanged({ Update-EnhancementControls; Save-AppState })
$imageTypeCombo.Add_SelectedIndexChanged({ Update-EnhancementControls; Save-AppState })
foreach ($stateControl in @($formatCombo, $strengthCombo, $scaleCombo)) {
    $stateControl.Add_SelectedIndexChanged({ Save-AppState })
}
foreach ($stateCheck in @($preserveAlphaCheck, $openFolderCheck, $faithfulCheck)) {
    $stateCheck.Add_CheckedChanged({ Save-AppState })
}
$finalWidthBox.Add_ValueChanged({ Save-AppState })
$finalHeightBox.Add_ValueChanged({ Save-AppState })

$dragEnterHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
}
$dragDropHandler = {
    param($sender, $eventArgs)
    $paths=[string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($script:activePage -eq 'Enhancement') {Add-ClarityImages $paths} else {Add-ImageFiles $paths}
}
$organizerDragEnterHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $paths = [string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        $hasFolder = @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -gt 0
        $eventArgs.Effect = if ($hasFolder) { [System.Windows.Forms.DragDropEffects]::Copy } else { [System.Windows.Forms.DragDropEffects]::None }
    } else { $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None }
}
$organizerDragDropHandler = {
    param($sender, $eventArgs)
    Add-OrganizerFoldersBatch -Paths ([string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
}
$spreadsheetDragDropHandler = {
    param($sender, $eventArgs)
    Add-SpreadsheetFoldersBatch -Paths ([string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
}
foreach ($organizerDropTarget in @($organizerContent, $organizerDropCard, $organizerDropTitle, $organizerDropDescription, $organizerLogHost, $organizerLogList)) {
    $organizerDropTarget.AllowDrop = $true
    $organizerDropTarget.Add_DragEnter($organizerDragEnterHandler)
    $organizerDropTarget.Add_DragDrop($organizerDragDropHandler)
}
foreach ($spreadsheetDropTarget in @($spreadsheetOpenContent, $spreadsheetDropCard, $spreadsheetDropTitle, $spreadsheetDropDescription, $spreadsheetListHost, $spreadsheetList)) {
    $spreadsheetDropTarget.AllowDrop = $true
    $spreadsheetDropTarget.Add_DragEnter($organizerDragEnterHandler)
    $spreadsheetDropTarget.Add_DragDrop($spreadsheetDragDropHandler)
}
$dropTargets = @(
    $form,
    $appShell,
    $mainLayout,
    $navigationSidebar,
    $listHost,
    $contentSplit,
    $contentSplit.Panel1,
    $contentSplit.Panel2,
    $listPanel,
    $list,
    $horizontalScrollHost,
    $previewHost,
    $previewLayout,
    $compareLayout,
    $previewBox,
    $resultPreviewBox
)
foreach ($dropTarget in $dropTargets) {
    $dropTarget.AllowDrop = $true
    $dropTarget.Add_DragEnter($dragEnterHandler)
    $dropTarget.Add_DragDrop($dragDropHandler)
}

function Get-OutputFormatForSource {
    param([string]$SourcePath)
    if ($formatCombo.SelectedIndex -ne 3) { return Get-SelectedOutputFormat }
    $extension = [System.IO.Path]::GetExtension($SourcePath).TrimStart('.').ToLowerInvariant()
    if ($extension -in @('jpg', 'jpeg', 'jfif')) { return 'jpg' }
    if ($extension -eq 'webp') { return 'webp' }
    if ($extension -in @('doc', 'docx')) { return 'docx' }
    if ($extension -in @('ppt', 'pptx')) { return 'pptx' }
    if ($extension -eq 'pdf') { return 'pdf' }
    return 'png'
}

function Set-ProcessingControlsEnabled {
    param([bool]$Enabled)
    foreach ($control in @(
        $addButton, $clearButton, $selectAllCheck, $invertButton, $sameFolder, $outputBox, $browseButton,
        $bgCombo, $sizeCombo, $formatCombo, $enhanceCombo, $strengthCombo, $scaleCombo, $imageTypeCombo,
        $preserveAlphaCheck, $openFolderCheck, $faithfulCheck, $finalWidthBox, $finalHeightBox, $apiSettingsButton,
        $homeNavigationButton, $settingsNavigationButton, $imageApiNavigationButton, $searchNavigationButton,
        $organizerButton, $changelogNavigationButton
    )) { $control.Enabled = $Enabled }
    $convertButton.Enabled = $Enabled
    $cancelButton.Enabled = -not $Enabled
    if ($Enabled) {
        $outputBox.Enabled = -not $sameFolder.Checked
        Update-EnhancementControls
    }
}

function Remove-JobTemporaryDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $root = [System.IO.Path]::GetFullPath($script:taskTempRoot).TrimEnd('\') + '\'
    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    if ($resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Complete-ProcessingBatch {
    if ($script:workerTimer) { $script:workerTimer.Stop() }
    $script:isConverting = $false
    Set-ProcessingControlsEnabled $true
    $progressBar.Value = if ($script:cancelRequested) { $progressBar.Value } else { 100 }
    $status.Text = if ($script:cancelRequested) {
        "处理已取消：成功 $($script:processingSuccess)，失败 $($script:processingFailed)，跳过 $($script:processingSkipped)"
    } else {
        "处理完成：成功 $($script:processingSuccess)，失败 $($script:processingFailed)，跳过 $($script:processingSkipped)"
    }
    Save-AppState
    if ($openFolderCheck.Checked -and $script:processingSuccess -gt 0 -and (Test-Path -LiteralPath $script:lastOutputDirectory -PathType Container)) {
        try {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = 'explorer.exe'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            [void]$startInfo.ArgumentList.Add($script:lastOutputDirectory)
            [void][System.Diagnostics.Process]::Start($startInfo)
        } catch { }
    }
    if ($script:processingFailed -gt 0 -and -not $SmokeTestConversion) {
        [System.Windows.Forms.MessageBox]::Show("部分文件处理失败。`n`n成功：$($script:processingSuccess) 项`n失败：$($script:processingFailed) 项`n跳过：$($script:processingSkipped) 项`n`n把鼠标移到失败项目上可查看原因。", '文件处理失败', 'OK', 'Warning') | Out-Null
    }
}

function Start-NextWorkerJob {
    if ($script:cancelRequested -or $script:processingIndex -ge $script:processingItems.Count) {
        if ($script:cancelRequested -and $script:processingIndex -lt $script:processingItems.Count) {
            for ($remaining = $script:processingIndex; $remaining -lt $script:processingItems.Count; $remaining++) {
                $remainingItem = $script:processingItems[$remaining]
                $remainingItem.SubItems[3].Text = '已跳过（已取消）'
                $script:processingSkipped++
            }
        }
        Complete-ProcessingBatch
        return
    }

    $item = $script:processingItems[$script:processingIndex]
    $sourcePath = [string]$item.Tag
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $item.SubItems[3].Text = '跳过：源文件不存在'
        $script:processingSkipped++
        $script:processingIndex++
        Start-NextWorkerJob
        return
    }

    $jobDirectory = $null
    try {
        $directory = if ($script:batchOptions.SameFolder) { [System.IO.Path]::GetDirectoryName($sourcePath) } else { $script:batchOptions.OutputDirectory }
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        $outputFormat = Get-OutputFormatForSource $sourcePath
        $suffix = switch ($script:batchOptions.Mode) {
            '保守清晰' { '_保守清晰' }
            'AI 模型高清' { "_AI高清_$($script:batchOptions.Scale)x" }
            'API 大模型清晰' { '_API清晰' }
            default { '_' + $outputFormat.ToUpperInvariant() }
        }
        $destination = if ($script:batchOptions.CustomNaming) {
            $customIndex = [int]$script:batchOptions.NameStart + $script:processingIndex
            New-SequentialOutputPath $directory ([string]$script:batchOptions.NamePrefix) $customIndex $outputFormat
        } else {
            New-ProcessedOutputPath $directory ([System.IO.Path]::GetFileNameWithoutExtension($sourcePath)) $outputFormat $suffix
        }
        $background = '#{0:X2}{1:X2}{2:X2}' -f $script:backgroundColor.R, $script:backgroundColor.G, $script:backgroundColor.B
        $sourceExtension = [IO.Path]::GetExtension($sourcePath).ToLowerInvariant()
        $isImageSource = $sourceExtension -in @('.png', '.jpg', '.jpeg', '.jfif', '.webp')
        $isImageOutput = $outputFormat -in @('jpg', 'png', 'webp')
        if (-not ($isImageSource -and $isImageOutput)) {
            $jobDirectory = Join-Path $script:taskTempRoot ([Guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($jobDirectory) | Out-Null
            $jobPath = Join-Path $jobDirectory 'job.json'
            $progressPath = Join-Path $jobDirectory 'progress.json'
            $resultPath = Join-Path $jobDirectory 'result.json'
            $job = [PSCustomObject]@{
                SourcePath = $sourcePath; OutputPath = $destination; OutputFormat = $outputFormat
                FinalWidth = $script:batchOptions.FinalWidth; FinalHeight = $script:batchOptions.FinalHeight
                Background = $background; MagickPath = $script:magickPath; PdfToPpmPath = $script:pdfToPpmPath
                TempDirectory = $jobDirectory; ProgressPath = $progressPath; ResultPath = $resultPath
            }
            [IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:powerShellPath
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $script:documentWorkerScriptPath, '-JobPath', $jobPath)) { [void]$startInfo.ArgumentList.Add($argument) }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw '无法启动后台文档转换进程。' }
            $script:workerProcess = $process
            $script:currentJob = [PSCustomObject]@{
                Item = $item; Directory = $jobDirectory; ProgressPath = $progressPath; ResultPath = $resultPath; Destination = $destination
                Direct = $false; OutputTask = $null; ErrorTask = $null; Document = $true
            }
            $item.SubItems[3].Text = '文档转换中…'
            $status.Text = "正在处理 $($script:processingIndex + 1) / $($script:processingItems.Count)：$($item.Text)"
            $script:workerTimer.Start()
            return
        }
        if ($script:batchOptions.Mode -eq '关闭') {
            # 普通格式/尺寸转换直接启动 ImageMagick，省去每张图片启动完整 PowerShell worker 的冷启动时间。
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:magickPath
            $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName($script:magickPath)
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $arguments = [System.Collections.Generic.List[string]]::new()
            foreach ($argument in @($sourcePath, '-auto-orient', '-colorspace', 'sRGB')) { $arguments.Add($argument) }
            $keepAlpha = [bool]$script:batchOptions.PreserveAlpha -and $outputFormat -ne 'jpg'
            $fitBackground = if ($keepAlpha) { 'none' } else { $background }
            if ($script:batchOptions.FinalWidth -gt 0 -and $script:batchOptions.FinalHeight -gt 0) {
                foreach ($argument in @(
                    '-filter', 'Lanczos', '-resize', ("{0}x{1}" -f $script:batchOptions.FinalWidth, $script:batchOptions.FinalHeight),
                    '-gravity', 'center', '-background', $fitBackground, '-extent', ("{0}x{1}" -f $script:batchOptions.FinalWidth, $script:batchOptions.FinalHeight)
                )) { $arguments.Add($argument) }
            }
            if (-not $keepAlpha) {
                foreach ($argument in @('-background', $background, '-alpha', 'remove', '-alpha', 'off')) { $arguments.Add($argument) }
            }
            switch ($outputFormat) {
                'jpg' { foreach ($argument in @('-sampling-factor', '4:4:4', '-quality', '100')) { $arguments.Add($argument) } }
                'webp' { foreach ($argument in @('-quality', '100', '-define', 'webp:lossless=true')) { $arguments.Add($argument) } }
                default { foreach ($argument in @('-define', 'png:compression-level=6')) { $arguments.Add($argument) } }
            }
            $arguments.Add($destination)
            foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add($argument) }
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw '无法启动快速转换引擎。' }
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()
            $script:workerProcess = $process
            $script:currentJob = [PSCustomObject]@{
                Item = $item; Directory = $null; ProgressPath = $null; ResultPath = $null; Destination = $destination
                Direct = $true; OutputTask = $outputTask; ErrorTask = $errorTask
            }
        }
        else {
            $jobDirectory = Join-Path $script:taskTempRoot ([Guid]::NewGuid().ToString('N'))
            [System.IO.Directory]::CreateDirectory($jobDirectory) | Out-Null
            $jobPath = Join-Path $jobDirectory 'job.json'
            $progressPath = Join-Path $jobDirectory 'progress.json'
            $resultPath = Join-Path $jobDirectory 'result.json'
            $modelName = if ($script:batchOptions.ImageType -eq '插画') { 'realesrgan-x4plus-anime' } elseif ($script:batchOptions.Faithful) { 'realesrnet-x4plus' } else { 'realesrgan-x4plus' }
            $workerStrength = if ($script:batchOptions.Mode -eq 'AI 模型高清') {
                switch ($script:batchOptions.Strength) { '轻微' { '保守' } '较强' { '明显' } default { '标准' } }
            } else { $script:batchOptions.Strength }
            $job = [PSCustomObject]@{
                SourcePath = $sourcePath; OutputPath = $destination; OutputFormat = $outputFormat
                Mode = $script:batchOptions.Mode; Strength = $workerStrength; Scale = $script:batchOptions.Scale
                FinalWidth = $script:batchOptions.FinalWidth; FinalHeight = $script:batchOptions.FinalHeight
                ImageType = $script:batchOptions.ImageType; PreserveAlpha = $script:batchOptions.PreserveAlpha
                Background = $background; TileSize = 256; ModelName = $modelName
                MagickPath = $script:magickPath; RealEsrganPath = $script:realEsrganPath; ModelPath = $script:realEsrganModelPath
                TempDirectory = $jobDirectory; ProgressPath = $progressPath; ResultPath = $resultPath
                ApiConfig = if ($script:batchOptions.Mode -eq 'API 大模型清晰') { $script:batchOptions.ApiConfig } else { $null }
            }
            [System.IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:powerShellPath
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $script:workerScriptPath, '-JobPath', $jobPath)) { [void]$startInfo.ArgumentList.Add($argument) }
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw '无法启动后台图片处理进程。' }
            $script:workerProcess = $process
            $script:currentJob = [PSCustomObject]@{
                Item = $item; Directory = $jobDirectory; ProgressPath = $progressPath; ResultPath = $resultPath; Destination = $destination
                Direct = $false; OutputTask = $null; ErrorTask = $null
            }
        }
        $item.SubItems[3].Text = '处理中…'
        $status.Text = "正在处理 $($script:processingIndex + 1) / $($script:processingItems.Count)：$($item.Text)"
        $script:workerTimer.Start()
    }
    catch {
        if ($jobDirectory) { Remove-JobTemporaryDirectory $jobDirectory }
        $item.SubItems[3].Text = '失败：' + $_.Exception.Message
        $item.ToolTipText = $_.Exception.ToString()
        $item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#C43D4B')
        $script:processingFailed++
        $script:processingIndex++
        Start-NextWorkerJob
    }
}

$script:workerTimer = [System.Windows.Forms.Timer]::new()
$script:workerTimer.Interval = 100
$script:workerTimer.Add_Tick({
    if (-not $script:currentJob -or -not $script:workerProcess) { return }
    $jobState = $script:currentJob
    try {
        if (-not [bool]$jobState.Direct -and (Test-Path -LiteralPath $jobState.ProgressPath -PathType Leaf)) {
            try {
                $workerProgress = Get-Content -LiteralPath $jobState.ProgressPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $overall = [Math]::Floor((($script:processingIndex + ([double]$workerProgress.Percent / 100.0)) / $script:processingItems.Count) * 100)
                $progressBar.Value = [Math]::Max(0, [Math]::Min(100, $overall))
                $status.Text = "正在处理 $($script:processingIndex + 1) / $($script:processingItems.Count)：$($workerProgress.Phase)"
            } catch { }
        }
        if (-not $script:workerProcess.HasExited) { return }
        if ($SmokeTestConversion) { Write-Host 'Smoke conversion: engine exited.' }
        $script:workerTimer.Stop()
        $script:workerProcess.WaitForExit()
        $exitCode = $script:workerProcess.ExitCode
        if ($SmokeTestConversion) { Write-Host "Smoke conversion: exit code $exitCode; collecting output." }
        $directOutput = if ([bool]$jobState.Direct) { $jobState.OutputTask.GetAwaiter().GetResult() } else { '' }
        $directError = if ([bool]$jobState.Direct) { $jobState.ErrorTask.GetAwaiter().GetResult() } else { '' }
        if ($SmokeTestConversion) { Write-Host 'Smoke conversion: output collected.' }
        $script:workerProcess.Dispose()
        $script:workerProcess = $null
        $item = $jobState.Item
        if ($script:cancelRequested) {
            $item.SubItems[3].Text = '已取消'
            $script:processingSkipped++
        } elseif ([bool]$jobState.Direct) {
            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $jobState.Destination -PathType Leaf)) {
                $message = ($directError + "`n" + $directOutput).Trim()
                if ([string]::IsNullOrWhiteSpace($message)) { $message = "快速转换引擎退出代码：$exitCode" }
                throw $message
            }
            $item.SubItems[3].Text = '完成'
            $item.ToolTipText = "已保存：$($jobState.Destination)"
            $item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#14855F')
            $script:resultPaths[[string]$item.Tag] = [string]$jobState.Destination
            $script:lastOutputDirectory = [System.IO.Path]::GetDirectoryName([string]$jobState.Destination)
            $script:processingSuccess++
            if ([string]$item.Tag -eq [string]$script:lastActivePath) { Show-ImagePreview ([string]$item.Tag) }
        } elseif (Test-Path -LiteralPath $jobState.ResultPath -PathType Leaf) {
            $result = Get-Content -LiteralPath $jobState.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([bool]$result.Success) {
                $pageCount = if ($result.PSObject.Properties['PageCount']) { [int]$result.PageCount } else { 1 }
                $item.SubItems[3].Text = if ($pageCount -gt 1) { "完成 · $pageCount 页" } else { '完成' }
                $item.ToolTipText = if ($pageCount -gt 1) { "已保存 $pageCount 个页面文件；首个文件：$($result.OutputPath)" } else { "已保存：$($result.OutputPath)" }
                $item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#14855F')
                $script:resultPaths[[string]$item.Tag] = [string]$result.OutputPath
                $script:lastOutputDirectory = [System.IO.Path]::GetDirectoryName([string]$result.OutputPath)
                $script:processingSuccess++
                if ([string]$item.Tag -eq [string]$script:lastActivePath) { Show-ImagePreview ([string]$item.Tag) }
            } else {
                $item.SubItems[3].Text = '失败：' + [string]$result.Error
                $item.ToolTipText = [string]$result.Error
                $item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#C43D4B')
                $script:processingFailed++
            }
        } else {
            $item.SubItems[3].Text = '失败：后台进程未返回结果'
            $item.ToolTipText = '后台处理进程意外退出，未生成结果文件。'
            $item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#C43D4B')
            $script:processingFailed++
        }
    }
    catch {
        $script:workerTimer.Stop()
        if ($script:workerProcess) {
            try {
                if (-not $script:workerProcess.HasExited) { $script:workerProcess.Kill($true) }
                $script:workerProcess.Dispose()
            } catch { }
            $script:workerProcess = $null
        }
        $jobState.Item.SubItems[3].Text = '失败：' + $_.Exception.Message
        $jobState.Item.ToolTipText = $_.Exception.ToString()
        $jobState.Item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#C43D4B')
        $script:processingFailed++
    }
    finally {
        if (-not $script:workerProcess) {
            Remove-JobTemporaryDirectory $jobState.Directory
            $script:currentJob = $null
            $script:processingIndex++
            Start-NextWorkerJob
        }
    }
})

$cancelButton.Add_Click({
    if (-not $script:isConverting) { return }
    $script:cancelRequested = $true
    $cancelButton.Enabled = $false
    $status.Text = '正在取消当前任务并清理临时文件…'
    if ($script:workerProcess -and -not $script:workerProcess.HasExited) {
        try { $script:workerProcess.Kill($true) } catch { }
    }
})

$convertButton.Add_Click({
    if ($script:isConverting) { return }
    $checkedItems = @($script:allItems | Where-Object Checked)
    if ($checkedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请至少勾选一个需要处理的文件。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $sameFolder.Checked -and [string]::IsNullOrWhiteSpace($outputBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show('请选择输出文件夹。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $script:workerScriptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $script:documentWorkerScriptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $script:magickPath -PathType Leaf) -or -not (Test-Path -LiteralPath $script:pdfToPpmPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show('本地转换组件尚未安装完整，找不到图片、PDF 或后台处理模块。', '处理组件不可用', 'OK', 'Warning') | Out-Null
        return
    }
    $processingMode = '关闭'
    if ($processingMode -eq 'API 大模型清晰') {
        try { Test-ImageApiConfig $script:imageApiConfig }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show('请先完成 API 接入配置：' + $_.Exception.Message, 'API 配置', 'OK', 'Warning')
            return
        }
    }
    if ($processingMode -eq 'AI 模型高清' -and -not (Test-Path -LiteralPath $script:realEsrganPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show('AI 高清引擎尚未安装或不可用。保守清晰仍可正常使用。', 'AI 引擎不可用', 'OK', 'Warning') | Out-Null
        return
    }
    $targetSize = Get-SelectedOutputSize
    $script:batchOptions = [PSCustomObject]@{
        SameFolder = [bool]$sameFolder.Checked; OutputDirectory = [string]$outputBox.Text
        CustomNaming = [bool]$script:customNamingEnabled; NamePrefix = [string]$script:customNamePrefix; NameStart = [int]$script:customNameStart
        Mode = $processingMode; Strength = [string]$strengthCombo.SelectedItem
        ApiConfig = $script:imageApiConfig.Clone()
        Scale = Get-SelectedScale; ImageType = [string]$imageTypeCombo.SelectedItem
        PreserveAlpha = [bool]$preserveAlphaCheck.Checked; Faithful = [bool]$faithfulCheck.Checked
        FinalWidth = $targetSize.Width; FinalHeight = $targetSize.Height
    }
    $script:processingItems = $checkedItems
    $script:processingIndex = 0
    $script:processingSuccess = 0
    $script:processingFailed = 0
    $script:processingSkipped = 0
    $script:cancelRequested = $false
    $script:lastOutputDirectory = $null
    $script:isConverting = $true
    $progressBar.Value = 0
    Set-ProcessingControlsEnabled $false
    Start-NextWorkerJob
})

function Load-AppState {
    if (-not (Test-Path -LiteralPath $script:statePath -PathType Leaf)) { return }
    $script:isLoadingState = $true
    try {
        $state = Get-Content -LiteralPath $script:statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedActivePath = $null
        if ($state.PSObject.Properties['LastActivePath']) {
            $savedActivePath = [string]$state.LastActivePath
        }
        if ($state.PSObject.Properties['OutputSize']) {
            $savedSizeIndex = $sizeCombo.Items.IndexOf([string]$state.OutputSize)
            if ($savedSizeIndex -ge 0) { $sizeCombo.SelectedIndex = $savedSizeIndex }
        }
        foreach ($setting in @(
            @('OutputFormat', $formatCombo), @('EnhancementMode', $enhanceCombo),
            @('EnhancementStrength', $strengthCombo), @('Scale', $scaleCombo), @('ImageType', $imageTypeCombo)
        )) {
            if ($state.PSObject.Properties[$setting[0]]) {
                $savedIndex = $setting[1].Items.IndexOf([string]$state.($setting[0]))
                if ($savedIndex -ge 0) { $setting[1].SelectedIndex = $savedIndex }
            }
        }
        if ($state.PSObject.Properties['PreserveAlpha']) { $preserveAlphaCheck.Checked = [bool]$state.PreserveAlpha }
        if ($state.PSObject.Properties['OpenFolder']) { $openFolderCheck.Checked = [bool]$state.OpenFolder }
        if ($state.PSObject.Properties['FaithfulMode']) { $faithfulCheck.Checked = [bool]$state.FaithfulMode }
        if ($state.PSObject.Properties['CustomWidth']) { $finalWidthBox.Value = [Math]::Max($finalWidthBox.Minimum, [Math]::Min($finalWidthBox.Maximum, [decimal]$state.CustomWidth)) }
        if ($state.PSObject.Properties['CustomHeight']) { $finalHeightBox.Value = [Math]::Max($finalHeightBox.Minimum, [Math]::Min($finalHeightBox.Maximum, [decimal]$state.CustomHeight)) }
        if ($state.PSObject.Properties['SameFolder']) { $sameFolder.Checked = [bool]$state.SameFolder }
        if ($state.PSObject.Properties['OutputDirectory']) { $outputBox.Text = [string]$state.OutputDirectory }
        if ($state.PSObject.Properties['CustomNamingEnabled']) { $script:customNamingEnabled = [bool]$state.CustomNamingEnabled }
        if ($state.PSObject.Properties['CustomNamePrefix'] -and [string]$state.CustomNamePrefix -in @('主图', '副图', 'A')) { $script:customNamePrefix = [string]$state.CustomNamePrefix }
        if ($state.PSObject.Properties['CustomNameStart']) { $script:customNameStart = [Math]::Max(1, [Math]::Min(999999, [int]$state.CustomNameStart)) }
        $savedOrganizerPath = if ($state.PSObject.Properties['DingTalkOrganizerPath']) {
            [string]$state.DingTalkOrganizerPath
        } elseif ($state.PSObject.Properties['DesktopOrganizerPath']) {
            [string]$state.DesktopOrganizerPath
        } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($savedOrganizerPath)) {
            $script:organizerPath = Resolve-DingTalkOrganizerPath -SavedPath $savedOrganizerPath -DesktopPath $defaultDesktopPath
            [void][System.IO.Directory]::CreateDirectory($script:organizerPath)
        }
        if ($state.PSObject.Properties['DesktopOrganizerEnabled']) {
            $script:organizerEnabled = [bool]$state.DesktopOrganizerEnabled
        }
        if ($state.PSObject.Properties['OpenSpreadsheetAfterOrganization']) {
            $script:organizerOpenSpreadsheetEnabled = [bool]$state.OpenSpreadsheetAfterOrganization
        }
        if ($state.PSObject.Properties['SpreadsheetTargetScreenEnabled']) {
            $script:organizerSpreadsheetScreenEnabled = [bool]$state.SpreadsheetTargetScreenEnabled
        }
        if ($state.PSObject.Properties['SpreadsheetTargetScreen']) {
            $script:organizerSpreadsheetScreenIndex = [Math]::Max(0, [int]$state.SpreadsheetTargetScreen - 1)
        }
        if ($state.PSObject.Properties['DynamicIslandEnabled']) {
            $script:dynamicIslandEnabled = [bool]$state.DynamicIslandEnabled
        }
        Update-EnhancementControls
        foreach ($record in @($state.Records)) {
            $path = [string]$record.Path
            if ([string]::IsNullOrWhiteSpace($path) -or $script:files.Contains($path)) { continue }

            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Add-ImageFiles @($path)
                $item = $script:allItems | Where-Object { [string]$_.Tag -eq $path } | Select-Object -First 1
            }
            else {
                $item = [System.Windows.Forms.ListViewItem]::new([System.IO.Path]::GetFileName($path))
                [void]$item.SubItems.Add('—')
                [void]$item.SubItems.Add('—')
                [void]$item.SubItems.Add('源文件不存在')
                $item.Tag = $path
                $item.Checked = $false
                $script:allItems.Add($item)
                $script:files.Add($path)
            }

            if ($item) {
                $item.Name = if ([string]::IsNullOrWhiteSpace([string]$record.AddedAt)) { [DateTime]::Now.ToString('o') } else { [string]$record.AddedAt }
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $item.Checked = [bool]$record.Checked
                    if (-not [string]::IsNullOrWhiteSpace([string]$record.Status)) {
                        $item.SubItems[3].Text = [string]$record.Status
                    }
                }
                if ($record.PSObject.Properties['OutputPath'] -and -not [string]::IsNullOrWhiteSpace([string]$record.OutputPath) -and (Test-Path -LiteralPath ([string]$record.OutputPath) -PathType Leaf)) {
                    $script:resultPaths[$path] = [string]$record.OutputPath
                    $item.ToolTipText = "已保存：$([string]$record.OutputPath)"
                }
            }
        }
        $script:lastActivePath = $savedActivePath
        $organizerPathBox.Text = $script:organizerPath
        $organizerSpreadsheetToggle.Checked = $script:organizerOpenSpreadsheetEnabled
        $organizerSpreadsheetScreenToggle.Checked = $script:organizerSpreadsheetScreenEnabled
        $organizerSpreadsheetScreenCombo.SelectedIndex = [Math]::Min($script:organizerSpreadsheetScreenIndex, $organizerSpreadsheetScreenCombo.Items.Count - 1)
        $organizerSpreadsheetScreenCombo.Enabled = $script:organizerSpreadsheetScreenEnabled
        $organizerIslandToggle.Checked = $script:dynamicIslandEnabled
        Apply-NameFilter
        Update-CheckedStatus
        if ($list.Items.Count -gt 0) {
            $restoreItem = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$script:lastActivePath)) {
                $restoreItem = $list.Items | Where-Object { [string]$_.Tag -eq $script:lastActivePath } | Select-Object -First 1
            }
            if (-not $restoreItem) { $restoreItem = $list.Items[0] }
            $restoreItem.Selected = $true
            $restoreItem.Focused = $true
            $script:lastActivePath = [string]$restoreItem.Tag
            Show-ImagePreview ([string]$restoreItem.Tag)
        }
    }
    catch {
        $status.Text = '历史记录读取失败：' + $_.Exception.Message
    }
    finally { $script:isLoadingState = $false }
}

$form.Add_Shown({
    [ReferenceUiDwm]::Apply($form.Handle)
    Update-Layout
    if ($script:organizerEnabled) {
        [void](Start-DesktopOrganizer -Path $script:organizerPath -Quiet)
    } else {
        Update-DesktopOrganizerUi
    }
    if ($script:dynamicIslandEnabled) { Show-DynamicIsland }
    Update-CheckedStatus
    if ($script:allItems.Count -eq 0) { $status.Text = Get-LocalEngineStatusText }
    $desired = $contentSplit.Width - 420
    $maximum = $contentSplit.Width - $contentSplit.Panel2MinSize - $contentSplit.SplitterWidth
    if ($desired -ge $contentSplit.Panel1MinSize -and $desired -le $maximum) {
        $contentSplit.SplitterDistance = $desired
    }
    Update-HorizontalScrollRange
    Update-VerticalScrollRange
    $verticalScrollSyncTimer.Start()
})
$form.Add_FormClosed({
    Close-ClarityWorkspace
    Stop-LocalSearch
    $verticalScrollSyncTimer.Stop()
    $verticalScrollSyncTimer.Dispose()
    Stop-PreviewWorker
    if ($script:previewTimer) {
        $script:previewTimer.Dispose()
        $script:previewTimer = $null
    }
    if ($script:previewRequestTimer) {
        $script:previewRequestTimer.Dispose()
        $script:previewRequestTimer = $null
    }
    Hide-DynamicIsland
    Stop-DesktopOrganizer -PreserveEnabledPreference
    if ($script:organizerTimer) {
        $script:organizerTimer.Dispose()
        $script:organizerTimer = $null
    }
    if ($script:spreadsheetWindowMoveTimer) {
        $script:spreadsheetWindowMoveTimer.Dispose()
        $script:spreadsheetWindowMoveTimer = $null
    }
    if ($script:dynamicIslandResetTimer) {
        $script:dynamicIslandResetTimer.Dispose()
        $script:dynamicIslandResetTimer = $null
    }
    if ($script:workerTimer) {
        $script:workerTimer.Stop()
        $script:workerTimer.Dispose()
    }
    if ($script:workerProcess -and -not $script:workerProcess.HasExited) {
        try { $script:workerProcess.Kill($true) } catch { }
    }
    if ($script:currentJob) { Remove-JobTemporaryDirectory $script:currentJob.Directory }
    Save-AppState -Immediate
    if ($script:stateSaveTimer) {
        $script:stateSaveTimer.Stop()
        $script:stateSaveTimer.Dispose()
        $script:stateSaveTimer = $null
    }
    if ($previewBox.Image) {
        $previewBox.Image.Dispose()
        $previewBox.Image = $null
    }
    if ($resultPreviewBox.Image) {
        $resultPreviewBox.Image.Dispose()
        $resultPreviewBox.Image = $null
    }
    Dispose-NavigationIcons
    if ($organizerToolTip) { $organizerToolTip.Dispose() }
})

Load-AppState
Initialize-ClarityState
Show-ImageWorkspace -Enhancement:$OpenEnhancement
if ($SmokeTest) {
    $navigationClick = [System.Windows.Forms.Control].GetMethod('OnClick', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $enhanceCombo.SelectedItem = 'API 大模型清晰'
    [void]$navigationClick.Invoke($imageApiNavigationButton, @([System.EventArgs]::Empty))
    if ($script:activePage -ne 'Enhancement' -or $clarityHeading.Text -ne '图片清晰' -or $clarityPage.Parent -ne $appShell -or $script:clarity.List -eq $list) { throw '图片清晰独立页面切换失败。' }
    if ($enhanceCombo.Parent -eq $settings -or $apiSettingsButton.Parent -eq $settings) { throw '主页仍包含清晰设置。' }
    [void]$navigationClick.Invoke($enhanceNavigationButton, @([System.EventArgs]::Empty))
    if ($script:activePage -ne 'Enhancement') { throw '第四个图标仍有点击跳转。' }
    [void]$navigationClick.Invoke($homeNavigationButton, @([System.EventArgs]::Empty))
    if ($script:activePage -ne 'Images' -or $title.Text -ne '图片格式与尺寸转换' -or $convertButton.Text -eq '上传并清晰') { throw '主页未隔离图片清晰功能。' }
    Write-Host 'Enhancement navigation and reserved fourth icon: passed.'
}
if ($SmokeTestClarityConversion) {
    if (-not $SmokeTest) { throw '独立清晰处理测试必须使用 -SmokeTest。' }
    [void][IO.Directory]::CreateDirectory($script:dataDirectory)
    $fixture=Join-Path $script:dataDirectory 'clarity-fixture.png'
    & $script:magickPath -size 96x96 gradient:blue-white $fixture
    $homeCount=$list.Items.Count
    Show-ImageWorkspace -Enhancement
    [void]$form.Handle
    [void]$script:clarity.List.Handle
    Add-ClarityImages @($fixture)
    $script:clarity.Mode.SelectedItem='保守清晰'
    Start-ClarityBatch
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while ($script:clarity.Busy -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
    if ($script:clarity.Busy -or $script:clarity.Success -ne 1 -or $script:clarity.Failed -ne 0 -or $list.Items.Count -ne $homeCount) { throw '独立清晰处理或列表隔离测试失败。' }
    if ($sizeCombo.SelectedIndex -ne 0 -or $formatCombo.SelectedItem -ne 'JPG') { throw '独立清晰修改了主页输出设置。' }
    Update-ClarityPreview
    $previewDeadline=[DateTime]::UtcNow.AddSeconds(15)
    while ($script:clarity.PreviewProcess -and [DateTime]::UtcNow -lt $previewDeadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
    if (-not $script:clarity.Original.Image -or -not $script:clarity.Result.Image) {throw '独立清晰原图和结果预览失败。'}
    Save-ClarityState -ForTest
    $savedClarity=Get-Content (Join-Path $script:dataDirectory 'clarity-state.json') -Raw | ConvertFrom-Json
    if ($savedClarity.Records.Count -ne 1 -or $savedClarity.Format -ne 'PNG' -or -not (Test-Path $savedClarity.Records[0].Result)) { throw '独立清晰记录保存失败。' }
    $nextFixture=Join-Path $script:dataDirectory 'clarity-next-fixture.png'
    & $script:magickPath -size 80x80 gradient:red-white $nextFixture
    $previousClarityItem=$script:clarity.List.Items[0]
    Add-ClarityImages @($nextFixture)
    $newClarityItem=$script:clarity.List.Items[1]
    if ($previousClarityItem.Checked -or -not $newClarityItem.Checked -or -not $newClarityItem.Selected) { throw '清晰页新增图片未取消旧图片勾选。' }
    Start-ClarityBatch
    $script:clarity.Cancelled=$true
    if ($script:clarity.Process -and -not $script:clarity.Process.HasExited) {$script:clarity.Process.Kill($true)}
    $cancelDeadline=[DateTime]::UtcNow.AddSeconds(10)
    while ($script:clarity.Busy -and [DateTime]::UtcNow -lt $cancelDeadline) {[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    if ($script:clarity.Busy -or $script:clarity.Process -or $script:clarity.JobDirectory) {throw '独立清晰取消或临时目录清理失败。'}
    $script:clarity.List.Items[0].SubItems[1].Text='完成'
    $script:clarity.Status.Text='测试通过：清晰处理、双图预览、记录保存及取消'
    Write-Host 'Independent clarity queue, local enhancement and home isolation: passed.'
    Show-ImageWorkspace
}
$inputFilesLoadMilliseconds = 0.0
if ($InputFiles) {
    if ($script:isSmokeRun) {
        # 性能测试模拟真实拖放时窗口已经创建完毕的状态，排除首次创建 WinForms 句柄的固定开销。
        [void]$form.Handle
        [void]$list.Handle
        [System.Windows.Forms.Application]::DoEvents()
    }
    $inputFilesTimer = [System.Diagnostics.Stopwatch]::StartNew()
    if ($OpenEnhancement -and -not $script:isSmokeRun) { Add-ClarityImages $InputFiles } else { Add-ImageFiles $InputFiles }
    $inputFilesTimer.Stop()
    $inputFilesLoadMilliseconds = $inputFilesTimer.Elapsed.TotalMilliseconds
}
if ($SmokeTestPreview) {
    if (-not $SmokeTest -or -not $InputFiles -or $script:allItems.Count -eq 0) {
        throw 'SmokeTestPreview 需要同时指定 SmokeTest 和至少一张输入图片。'
    }
    $previewSmokeTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $expectedPreviewPath = [System.IO.Path]::GetFullPath([string]$InputFiles[0])
    $previewDeadline = [DateTime]::UtcNow.AddSeconds(8)
    while ([string]$script:displayedPreviewPath -ne $expectedPreviewPath -and [DateTime]::UtcNow -lt $previewDeadline) {
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(5)
    }
    $previewSmokeTimer.Stop()
    if ([string]$script:displayedPreviewPath -ne $expectedPreviewPath -or -not $previewBox.Image) {
        throw '快速图片预览冒烟测试超时。'
    }
    Write-Host ('Preview visible: {0:N0} ms.' -f $previewSmokeTimer.Elapsed.TotalMilliseconds)
}
if ($SmokeTestConversion) {
    if (-not $InputFiles -or $script:allItems.Count -eq 0) { throw 'SmokeTestConversion 需要至少一张输入图片。' }
    $enhanceCombo.SelectedIndex = 0
    $sameFolder.Checked = $true
    [void]$form.Handle
    [System.Windows.Forms.Application]::DoEvents()
    $script:batchOptions = [PSCustomObject]@{
        SameFolder = $true; OutputDirectory = ''; Mode = '关闭'; Strength = '标准'; Scale = 1
        CustomNaming = [bool]$SmokeTestCustomNaming; NamePrefix = '主图'; NameStart = 1
        ImageType = '商品照片'; PreserveAlpha = $true; Faithful = $false; FinalWidth = 0; FinalHeight = 0
    }
    $script:processingItems = @($script:allItems | Where-Object Checked)
    $script:processingIndex = 0
    $script:processingSuccess = 0
    $script:processingFailed = 0
    $script:processingSkipped = 0
    $script:cancelRequested = $false
    $script:lastOutputDirectory = $null
    $script:isConverting = $true
    Start-NextWorkerJob
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($script:isConverting -and [DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(10)
    }
    $successCount = $script:processingSuccess
    $failureCount = $script:processingFailed
    $customNamingResults = if ($SmokeTestCustomNaming) {
        @($script:processingItems | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$script:resultPaths[[string]$_.Tag]) })
    } else { @() }
    $stillConverting = $script:isConverting
    Stop-PreviewWorker
    Hide-DynamicIsland
    if ($script:workerProcess -and -not $script:workerProcess.HasExited) { try { $script:workerProcess.Kill($true) } catch { } }
    foreach ($smokeTimer in @($verticalScrollSyncTimer, $script:organizerTimer, $script:spreadsheetWindowMoveTimer, $script:workerTimer, $script:previewTimer, $script:previewRequestTimer, $script:stateSaveTimer, $script:dynamicIslandResetTimer)) {
        if ($smokeTimer) { try { $smokeTimer.Dispose() } catch { } }
    }
    $form.Dispose()
    Dispose-NavigationIcons
    if ($organizerToolTip) { $organizerToolTip.Dispose() }
    if (Test-Path -LiteralPath $script:dataDirectory) { Remove-Item -LiteralPath $script:dataDirectory -Recurse -Force }
    if ($stillConverting) { throw '快速转换冒烟测试超时。' }
    if ($failureCount -gt 0 -or $successCount -lt 1) { throw "快速转换冒烟测试失败：成功 $successCount，失败 $failureCount。" }
    if ($SmokeTestCustomNaming) {
        $expectedNames = @(for ($i = 1; $i -le $script:processingItems.Count; $i++) { "主图$i" })
        if (($customNamingResults -join '|') -ne ($expectedNames -join '|')) {
            throw "自定义命名验证失败：$($customNamingResults -join '、')"
        }
        Write-Host ('Custom naming: ' + ($customNamingResults -join '、'))
    }
    return
}
if ($SmokeTest -and -not [string]::IsNullOrWhiteSpace($SmokeTestScreenshotPath)) {
    function Initialize-SmokeControlTree {
        param([System.Windows.Forms.Control]$Control)
        [void]$Control.Handle
        foreach ($child in $Control.Controls) { Initialize-SmokeControlTree $child }
        try { $Control.PerformLayout() } catch { }
    }
    Initialize-SmokeControlTree $form
    Update-Layout
    $form.PerformLayout()
    $screenshotBitmap = [System.Drawing.Bitmap]::new($form.ClientSize.Width, $form.ClientSize.Height)
    try {
        $form.DrawToBitmap($screenshotBitmap, [System.Drawing.Rectangle]::new(0, 0, $screenshotBitmap.Width, $screenshotBitmap.Height))
        $screenshotBitmap.Save($SmokeTestScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $screenshotBitmap.Dispose() }
    if ($SmokeTestEnhancementScreenshotPath) {
        Show-ImageWorkspace -Enhancement
        Update-Layout
        $form.PerformLayout()
        Save-SmokeControlScreenshot -Control $form -Path $SmokeTestEnhancementScreenshotPath
        Show-ImageApiSettings -SmokeScreenshotPath ($SmokeTestEnhancementScreenshotPath + '.settings.png')
    }
    Stop-PreviewWorker
    Hide-DynamicIsland
    foreach ($smokeTimer in @($verticalScrollSyncTimer, $script:organizerTimer, $script:spreadsheetWindowMoveTimer, $script:workerTimer, $script:previewTimer, $script:previewRequestTimer, $script:stateSaveTimer, $script:dynamicIslandResetTimer)) {
        if ($smokeTimer) { try { $smokeTimer.Dispose() } catch { } }
    }
    Dispose-NavigationIcons
    if ($organizerToolTip) { $organizerToolTip.Dispose() }
    $form.Dispose()
    if (Test-Path -LiteralPath $script:dataDirectory) { Remove-Item -LiteralPath $script:dataDirectory -Recurse -Force }
    return
}
if ($SmokeTest) {
    if ($InputFiles) { Write-Host ('Immediate list add: {0:N1} ms for {1} image(s).' -f $inputFilesLoadMilliseconds, $script:allItems.Count) }
    Update-Layout
    Update-DesktopOrganizerUi
    foreach ($smokeItem in $script:allItems) {
        if ([string]$smokeItem.SubItems[1].Text -eq '待识别') {
            throw "轻量图片尺寸读取失败：$([string]$smokeItem.Tag)"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($SmokeTestChangelogScreenshotPath)) {
        function Invoke-SmokeNavigationClick {
            param([System.Windows.Forms.Control]$Control)
            $bindingFlags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
            $onClickMethod = [System.Windows.Forms.Control].GetMethod('OnClick', $bindingFlags)
            [void]$onClickMethod.Invoke($Control, @([System.EventArgs]::Empty))
        }
        $changelogPathForSmoke = Join-Path $PSScriptRoot 'CHANGELOG.md'
        if (-not (Test-Path -LiteralPath $changelogPathForSmoke -PathType Leaf)) {
            throw '发布目录缺少 CHANGELOG.md。'
        }
        Invoke-SmokeNavigationClick $changelogNavigationButton
        Update-Layout
        $form.PerformLayout()
        [System.Windows.Forms.Application]::DoEvents()
        $selectedBlue = [System.Drawing.ColorTranslator]::FromHtml('#74A7FF').ToArgb()
        $idleBlue = [System.Drawing.ColorTranslator]::FromHtml('#EDF2FA').ToArgb()
        if ($script:activePage -ne 'Changelog' -or $changelogBox.Text -notmatch '2026-09-03' -or $changelogPage.Parent -ne $appShell -or $changelogNavigationButton.BackColor.ToArgb() -ne $selectedBlue) {
            throw '更新日志页面未能正确显示。'
        }
        Invoke-SmokeNavigationClick $homeNavigationButton
        if ($script:activePage -ne 'Images' -or $homeNavigationButton.BackColor.ToArgb() -ne $selectedBlue -or $changelogNavigationButton.BackColor.ToArgb() -ne $idleBlue) {
            throw '更新日志返回图片主页失败。'
        }
        Invoke-SmokeNavigationClick $organizerButton
        if ($script:activePage -ne 'Organizer' -or $organizerButton.BackColor.ToArgb() -ne $selectedBlue) {
            throw '更新日志与文件夹整理页面互切失败。'
        }
        Invoke-SmokeNavigationClick $changelogNavigationButton
        [System.Windows.Forms.Application]::DoEvents()
        Save-SmokeControlScreenshot -Control $form -Path $SmokeTestChangelogScreenshotPath
    }
    if (-not [string]::IsNullOrWhiteSpace($SmokeTestSpreadsheetPageScreenshotPath)) {
        $spreadsheetSmokeRoot = Join-Path $script:dataDirectory 'SpreadsheetPageSmoke'
        $spreadsheetSmokeProjects = @('MX-BZ-11-抱枕套', 'MX-BZ-12-窗帘')
        foreach ($projectName in $spreadsheetSmokeProjects) {
            $projectPath = Join-Path $spreadsheetSmokeRoot $projectName
            $sourcePath = Join-Path $projectPath ($projectName + ' 源文件')
            [void][System.IO.Directory]::CreateDirectory($sourcePath)
            $extension = if ($projectName -like '*11*') { '.xlsx' } else { '.csv' }
            [System.IO.File]::WriteAllText((Join-Path $sourcePath ('需求明细' + $extension)), 'smoke')
        }
        Clear-SpreadsheetFolderQueue
        Add-SpreadsheetFoldersBatch -Paths @($spreadsheetSmokeProjects | ForEach-Object { Join-Path $spreadsheetSmokeRoot $_ })
        Show-DesktopOrganizerPage
        Show-OrganizerSubPage -Page 'Spreadsheets'
        $organizerSpreadsheetToggle.Checked = $false
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:organizerOpenSpreadsheetEnabled) { throw '整理后打开表格开关未能关闭。' }
        if ($organizerSpreadsheetScreenCombo.Enabled) { throw '未启用指定屏幕时，屏幕选择框不应可用。' }
        Save-AppState -Immediate
        $spreadsheetSwitchState = Get-Content -LiteralPath $script:statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([bool]$spreadsheetSwitchState.OpenSpreadsheetAfterOrganization) { throw '整理后打开表格开关关闭状态未保存。' }
        $organizerSpreadsheetToggle.Checked = $true
        $organizerSpreadsheetScreenToggle.Checked = $true
        $organizerSpreadsheetScreenCombo.SelectedIndex = [Math]::Min(1, $organizerSpreadsheetScreenCombo.Items.Count - 1)
        Save-AppState -Immediate
        Update-Layout
        $form.PerformLayout()
        [System.Windows.Forms.Application]::DoEvents()
        $spreadsheetSwitchState = Get-Content -LiteralPath $script:statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($script:organizerSubPage -ne 'Spreadsheets' -or $spreadsheetList.Items.Count -ne 2 -or -not $script:organizerOpenSpreadsheetEnabled -or -not [bool]$spreadsheetSwitchState.OpenSpreadsheetAfterOrganization -or -not [bool]$spreadsheetSwitchState.SpreadsheetTargetScreenEnabled -or [int]$spreadsheetSwitchState.SpreadsheetTargetScreen -ne ($organizerSpreadsheetScreenCombo.SelectedIndex + 1)) {
            throw '批量打开表格页面或开关验证失败。'
        }
        if (-not $organizerSpreadsheetScreenCombo.Enabled) { throw '启用指定屏幕后，屏幕选择框未启用。' }
        $positionSmokeForm = [System.Windows.Forms.Form]::new()
        try {
            $positionSmokeForm.Text = '表格窗口屏幕定位测试'
            $positionSmokeForm.Size = [System.Drawing.Size]::new(640, 420)
            $positionSmokeForm.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $positionSmokeWindow = [SpreadsheetWindowMover]::FindVisibleWindow('表格窗口屏幕定位测试')
            $positionSmokeScreens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object DeviceName)
            $positionSmokeScreenIndex = [Math]::Min($organizerSpreadsheetScreenCombo.SelectedIndex, $positionSmokeScreens.Count - 1)
            $script:spreadsheetWindowMoveJobs.Add([PSCustomObject]@{ Title = '表格窗口屏幕定位测试'; ScreenIndex = $positionSmokeScreenIndex; StartedAtUtc = [DateTime]::UtcNow })
            Move-PendingSpreadsheetWindows
            [System.Windows.Forms.Application]::DoEvents()
            if ($positionSmokeWindow -eq [IntPtr]::Zero -or $script:spreadsheetWindowMoveJobs.Count -ne 0) { throw '表格窗口屏幕定位调用失败。' }
            if ([System.Windows.Forms.Screen]::FromHandle($positionSmokeWindow).DeviceName -ne $positionSmokeScreens[$positionSmokeScreenIndex].DeviceName) {
                throw '表格窗口未移动到所选屏幕。'
            }
        }
        finally { $positionSmokeForm.Dispose() }
        Save-SmokeControlScreenshot -Control $form -Path $SmokeTestSpreadsheetPageScreenshotPath
    }
    $script:dynamicIslandEnabled = $true
    Show-DesktopOrganizerDialog
    Show-DynamicIsland
    [System.Windows.Forms.Application]::DoEvents()
    if (-not [string]::IsNullOrWhiteSpace($SmokeTestIslandGlowMode)) {
        $previewTitle = switch ($SmokeTestIslandGlowMode) {
            'Processing' { '正在整理文件夹' }
            'Complete' { '文件夹整理完成' }
            default { '桌面整理助手' }
        }
        $previewDetail = switch ($SmokeTestIslandGlowMode) {
            'Processing' { 'MX-BZ-01-抱枕套绿' }
            'Complete' { '已移动 12 项 · 继续监控新文件夹' }
            default { '正在监控钉钉下载文件夹' }
        }
        $previewColor = if ($SmokeTestIslandGlowMode -in @('Processing', 'Complete')) {
            [System.Drawing.ColorTranslator]::FromHtml('#35C98B')
        } else { [System.Drawing.ColorTranslator]::FromHtml('#56C8FF') }
        $script:dynamicIslandForm.SetContent($previewTitle, $previewDetail, $previewColor, $SmokeTestIslandGlowMode)
        $animationDeadline = [DateTime]::UtcNow.AddMilliseconds(180)
        while ([DateTime]::UtcNow -lt $animationDeadline) {
            [System.Windows.Forms.Application]::DoEvents()
            [System.Threading.Thread]::Sleep(4)
        }
        if ($script:dynamicIslandForm.TargetFrameInterval -gt 17 -or $script:dynamicIslandForm.AnimationFrameCount -lt 6) {
            throw "灵动岛高帧率动画验证失败：$($script:dynamicIslandForm.AnimationFrameCount) 帧。"
        }
    }
    if (-not $script:dynamicIslandForm -or $script:dynamicIslandForm.IsDisposed -or -not $script:dynamicIslandForm.TopMost) {
        throw '灵动岛悬浮窗创建失败。'
    }
    if (-not $script:dynamicIslandForm.LastLayerUpdateSucceeded) {
        throw '灵动岛逐像素透明图层更新失败。'
    }
    if (-not $script:dynamicIslandForm.IsMouseClickThrough) {
        throw '灵动岛鼠标穿透窗口样式未生效。'
    }
    $islandScreen = [System.Windows.Forms.Screen]::FromControl($script:dynamicIslandForm)
    if ($script:dynamicIslandForm.Top -le $islandScreen.WorkingArea.Top -or $script:dynamicIslandForm.Width -lt 300) {
        throw '灵动岛悬浮窗的位置或尺寸不符合预期。'
    }
    Save-SmokeControlScreenshot -Control $script:dynamicIslandForm -Path $SmokeTestIslandScreenshotPath
    Hide-DynamicIsland
    $script:dynamicIslandEnabled = $false
    Stop-PreviewWorker
    $verticalScrollSyncTimer.Dispose()
    if ($script:organizerTimer) { $script:organizerTimer.Dispose() }
    if ($script:spreadsheetWindowMoveTimer) { $script:spreadsheetWindowMoveTimer.Dispose() }
    if ($script:workerTimer) { $script:workerTimer.Dispose() }
    if ($script:previewTimer) { $script:previewTimer.Dispose() }
    if ($script:previewRequestTimer) { $script:previewRequestTimer.Dispose() }
    if ($script:stateSaveTimer) { $script:stateSaveTimer.Dispose() }
    if ($script:dynamicIslandResetTimer) { $script:dynamicIslandResetTimer.Dispose() }
    Dispose-NavigationIcons
    if ($organizerToolTip) { $organizerToolTip.Dispose() }
    $form.Dispose()
    if (Test-Path -LiteralPath $script:dataDirectory) { Remove-Item -LiteralPath $script:dataDirectory -Recurse -Force }
    return
}
. (Join-Path $PSScriptRoot 'modules\WebUi.ps1')
Start-WebUi
[void]$form.ShowDialog()
if ($SmokeTestWebUi -and $script:webTestError) { throw $script:webTestError }
if ($SmokeTestWebUi -and $script:webTestStage -ne 9) { throw "Web UI test incomplete at stage $script:webTestStage" }
