VERSION 5.00
Begin VB.UserControl pdRuler 
   Appearance      =   0  'Flat
   BackColor       =   &H00FFFFFF&
   ClientHeight    =   3600
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   4800
   ClipBehavior    =   0  'None
   DrawStyle       =   5  'Transparent
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   9.75
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   HasDC           =   0   'False
   ScaleHeight     =   240
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   320
   ToolboxBitmap   =   "pdRuler.ctx":0000
End
Attribute VB_Name = "pdRuler"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Viewport Ruler UI element
'Copyright 2018-2018 by Tanner Helland
'Created: 03/April/18
'Last updated: 03/April/18
'Last update: initial build
'
'At present, this control is only designed for use on PD's primary canvas.  A few things to note:
'
' 1) High DPI settings are handled automatically.
' 2) Coloration is automatically handled by PD's internal theming engine.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'User control support class.  Historically, many classes (and associated subclassers) were required by each user control,
' but I've since attempted to wrap these into a single master control support class.
Private WithEvents ucSupport As pdUCSupport
Attribute ucSupport.VB_VarHelpID = -1

'Rulers can be horizontal or vertical, obviously
Private m_Orientation As PD_Orientation

'This control relies on a number of "conversion maps" to move points between the current canvas space and this control's
' canvas space (where we render notches, text, etc).  The purposes of these objects are described in more detail in the
' UpdateControlLayout and RedrawBackBuffer functions.
Private m_CanvasOffsetX As Long, m_CanvasOffsetY As Long
Private m_imgCoordRectF As RectF

'"Step", notch iteration start, and notch iteration end of the current ruler.
' "Step" only needs to be updated if viewport zoom changes; loop start and end need to be updated on zoom
' *and* scroll events.
Private m_Step As Long, m_LoopStart As Long, m_LoopEnd As Long

'Rulers can render themselves in increments of base-10 (0, 1, 2... or 0, 10, 20... or 0, 100, 200...),
' or 5 (0, 5, 10... 100, 150, 200, 250...) or 2 (0, 2, 4... or 10, 12, 14, 16, 18...).  Different intervals
' require different notch strategies.  This value is cached in the UpdateControlLayout function, and used
' by the RedrawBackBuffer function to determine how/where sub-notches are rendered.
Private m_Interval As Long

'Current mouse position, if any - in both canvas and image coordinate spaces
Private m_MouseCanvasX As Double, m_MouseCanvasY As Double, m_MouseImgX As Double, m_MouseImgY As Double

'Vertical rulers require a special font object that has been rotated -90 degrees.  Because this is the only
' place in the program where we render sideways fonts, we dont want to clutter up PD's central font cache
' (as it would then have to compare escapement on every hit, which doesn't make sense).  Instead, we create
' this font just once and cache it locally.
Private m_VerticalFont As pdFont

'To improve responsiveness, our parent canvas can ask us to suspend automatic redraws while it repositions itself.
' After all repositioning is complete, it can then request a manual refresh; this means we only redraw *once*
' when our parent canvas is reflowed (as opposed to redrawing ourselves multiple times).
Private m_SuspendRedraws As Boolean

'Local list of themable colors.  This list includes all potential colors used by the control, regardless of state change
' or internal control settings.  The list is updated by calling the UpdateColorList function.
' (Note also that this list does not include variants, e.g. "BorderColor" vs "BorderColor_Hovered".  Variant values are
'  automatically calculated by the color management class, and they are retrieved by passing boolean modifiers to that
'  class, rather than treating every imaginable variant as a separate constant.)
Private Enum PDRULER_COLOR_LIST
    [_First] = 0
    PDR_Background = 0
    PDR_Text = 1
    PDR_Notch = 2
    PDR_Mouse = 3
    [_Last] = 3
    [_Count] = 4
End Enum

'Color retrieval and storage is handled by a dedicated class; this allows us to optimize theme interactions,
' without worrying about the details locally.
Private m_Colors As pdThemeColors

Public Function GetControlType() As PD_ControlType
    GetControlType = pdct_Ruler
End Function

Public Function GetControlName() As String
    GetControlName = UserControl.Extender.Name
End Function

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
Attribute Enabled.VB_UserMemId = -514
    Enabled = UserControl.Enabled
End Property

Public Property Let Enabled(ByVal newValue As Boolean)
    UserControl.Enabled = newValue
    PropertyChanged "Enabled"
    RedrawBackBuffer
End Property

Public Property Get Orientation() As PD_Orientation
    Orientation = m_Orientation
End Property

Public Property Let Orientation(ByVal newOrientation As PD_Orientation)
    If (newOrientation <> m_Orientation) Then
        m_Orientation = newOrientation
        PropertyChanged "Orientation"
    End If
End Property

'hWnds aren't exposed by default
Public Property Get hWnd() As Long
Attribute hWnd.VB_UserMemId = -515
    hWnd = UserControl.hWnd
End Property

'Container hWnd must be exposed for external tooltip handling
Public Property Get ContainerHwnd() As Long
    ContainerHwnd = UserControl.ContainerHwnd
End Property

'To support high-DPI settings properly, we expose specialized move+size functions
Public Function GetLeft() As Long
    GetLeft = ucSupport.GetControlLeft
End Function

Public Sub SetLeft(ByVal newLeft As Long)
    ucSupport.RequestNewPosition newLeft, , True
End Sub

Public Function GetTop() As Long
    GetTop = ucSupport.GetControlTop
End Function

Public Sub SetTop(ByVal newTop As Long)
    ucSupport.RequestNewPosition , newTop, True
End Sub

Public Function GetWidth() As Long
    GetWidth = ucSupport.GetControlWidth
End Function

Public Sub SetWidth(ByVal newWidth As Long)
    ucSupport.RequestNewSize newWidth, , True
End Sub

Public Function GetHeight() As Long
    GetHeight = ucSupport.GetControlHeight
End Function

Public Sub SetHeight(ByVal newHeight As Long)
    ucSupport.RequestNewSize , newHeight, True
End Sub

Public Sub SetPositionAndSize(ByVal newLeft As Long, ByVal newTop As Long, ByVal newWidth As Long, ByVal newHeight As Long)
    ucSupport.RequestFullMove newLeft, newTop, newWidth, newHeight, True
End Sub

Private Sub ucSupport_RepaintRequired(ByVal updateLayoutToo As Boolean)
    If updateLayoutToo Then UpdateControlLayout Else RedrawBackBuffer
End Sub

'Because this control can be shown or hidden "on the fly" during a given session, we don't render it when it's invisible.
' If it is suddenly shown, we need to ensure its contents are up-to-date.
Private Sub ucSupport_VisibilityChange(ByVal newVisibility As Boolean)
    If newVisibility Then UpdateControlLayout
End Sub

Private Sub UserControl_Initialize()
    
    'Initialize a master user control support class
    Set ucSupport = New pdUCSupport
    ucSupport.RegisterControl UserControl.hWnd, False
    
    'Prep the color manager and load default colors
    Set m_Colors = New pdThemeColors
    Dim colorCount As PDRULER_COLOR_LIST: colorCount = [_Count]
    m_Colors.InitializeColorList "PDRuler", colorCount
    If Not pdMain.IsProgramRunning() Then UpdateColorList
    
End Sub

Private Sub UserControl_InitProperties()
    Me.Enabled = True
    Me.Orientation = pdo_Horizontal
End Sub

'At run-time, painting is handled by PD's pdWindowPainter class.  In the IDE, however, we must rely on VB's internal paint event.
Private Sub UserControl_Paint()
    If (Not pdMain.IsProgramRunning()) Then ucSupport.RequestIDERepaint UserControl.hDC
End Sub

Private Sub UserControl_ReadProperties(PropBag As PropertyBag)
    With PropBag
        Me.Enabled = .ReadProperty("Enabled", True)
        Me.Orientation = .ReadProperty("Orientation", pdo_Horizontal)
    End With
End Sub

Private Sub UserControl_Resize()
    If (Not pdMain.IsProgramRunning()) Then ucSupport.NotifyIDEResize UserControl.Width, UserControl.Height
End Sub

Private Sub UserControl_WriteProperties(PropBag As PropertyBag)
    With PropBag
        .WriteProperty "Enabled", Me.Enabled, True
        .WriteProperty "Orientation", m_Orientation, pdo_Horizontal
    End With
End Sub

Public Sub NotifyViewportChange()
    UpdateControlLayout True
End Sub

Public Sub NotifyMouseCoords(ByVal canvasX As Double, ByVal canvasY As Double, ByVal imgX As Double, ByVal imgY As Double, Optional ByVal clearCoords As Boolean = False)
    
    'When the mouse leaves the canvas, set the mouse trackers to off-screen coordinates
    If clearCoords Then
        m_MouseCanvasX = -90000#
        m_MouseCanvasY = -90000#
        m_MouseImgX = -90000#
        m_MouseImgY = -90000#
    Else
        m_MouseCanvasX = canvasX
        m_MouseCanvasY = canvasY
        m_MouseImgX = imgX
        m_MouseImgY = imgY
    End If
    
    RedrawBackBuffer True
    
End Sub

Public Sub SetRedrawSuspension(ByVal newState As Boolean, Optional ByVal redrawImmediately As Boolean = False)
    m_SuspendRedraws = newState
    If (Not m_SuspendRedraws) And redrawImmediately Then UpdateControlLayout True
End Sub

'Because this control automatically forces all internal buttons to identical sizes, we have to recalculate a number
' of internal sizing metrics whenever the control size changes.
Private Sub UpdateControlLayout(Optional ByVal redrawImmediately As Boolean = False)
    
    If m_SuspendRedraws Then Exit Sub
    
    'Retrieve DPI-aware control dimensions from the support class
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    'When prepping the layout of this control, we need to know three critical things:
    ' 1) Our position on-screen
    ' 2) The current canvas's position on-screen
    ' 3) The coordinate rect of the active image, as represented in the current viewport
    
    'From these three things we can construct a valid ruler.
    ' (Similarly, if no image is active, we can't do a damn thing.)
    Dim okToDraw As Boolean
    okToDraw = (g_OpenImageCount > 0)
    If okToDraw Then okToDraw = (Not pdImages(g_CurrentImage) Is Nothing)
    If okToDraw Then okToDraw = pdImages(g_CurrentImage).IsActive
    If okToDraw Then okToDraw = (Not g_WindowManager Is Nothing)
    
    If okToDraw Then
        
        'Start by retrieving our on-screen position, and the main canvas's on-screen position
        Dim myRectL As winRect, canvasRectL As winRect
        g_WindowManager.GetWindowRect_API Me.hWnd, myRectL
        g_WindowManager.GetWindowRect_API FormMain.MainCanvas(0).GetCanvasViewHWnd(), canvasRectL
        
        'Because these two coordinate spaces use the same internal scale (e.g. the ruler uses the same zoom and
        ' scroll settings as the canvas does), we can freely convert between them by simple translation.
        m_CanvasOffsetX = (canvasRectL.x1 - myRectL.x1)
        m_CanvasOffsetY = (canvasRectL.y1 - myRectL.y1)
        
        'Next, we want to figure out how to convert between ruler positions and *image* positions.  This is very close to
        ' mapping between canvas and image positions; in fact, all we need to modify is adding the offsets we discovered above!
        Dim imgTop As Double, imgLeft As Double
        Drawing.ConvertCanvasCoordsToImageCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), 0 - m_CanvasOffsetX, 0 - m_CanvasOffsetY, imgLeft, imgTop
        
        'For the right and bottom parameters, grab our client rect and the canvas's client rect, and add the difference between
        ' them to the total (including the offset calculated above).  This will tell us what the right/bottom of *our* control
        ' represents, in image coordinates.
        Dim imgRight As Double, imgBottom As Double, myClientRectL As winRect, canvasClientRectL As winRect
        g_WindowManager.GetClientWinRect Me.hWnd, myClientRectL
        g_WindowManager.GetClientWinRect FormMain.MainCanvas(0).GetCanvasViewHWnd(), canvasClientRectL
        
        Dim xOffset As Long, yOffset As Long
        xOffset = (myClientRectL.x2 - canvasClientRectL.x2) - m_CanvasOffsetX
        yOffset = (myClientRectL.y2 - canvasClientRectL.y2) - m_CanvasOffsetY
        Drawing.ConvertCanvasCoordsToImageCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), canvasClientRectL.x2 + xOffset, canvasClientRectL.y2 + yOffset, imgRight, imgBottom
        
        'We now know the rectangle - in image coordinates - represented by the current canvas.  Place this data in a
        ' module-level rect that we can freely use in RedrawBackBuffer.  (Note that we actually store right/bottom
        ' coordinates instead of width/height - this is probably a bad idea, but we make the same note in the
        ' RedrawBackBuffer sub, and it's not worth creating a custom struct just for this!)
        With m_imgCoordRectF
            .Left = imgLeft
            .Top = imgTop
            .Width = imgRight
            .Height = imgBottom
        End With
        
        'Before exiting, we want to compute a "step" factor for the ruler.  The "step" factor controls
        ' the numeric interval between notches, and it is a function of the current viewport zoom.
        ' (FYI, it's possible to optimize away this step on scroll events, seeing as zoom hasn't changed,
        ' but I don't currently have a fine-grained way to pass those notifications - and because the perf
        ' impact is unmeasurably small, I haven't gone to the trouble of solving this.  Maybe later!)
        '
        'The primary goal here is to cram as many numeric text labels as we can into the available ruler space,
        ' without overlapping neighboring lines (while also ensuring some amount of aesthetically pleasing
        ' padding between numbers).  At present this is locked to base-10 intervals; in the future we will
        ' expand it to support more fine-grained options.
        
        'Start by retrieving a copy of the current UI font.  We will use this to determine the length required
        ' by a four-digit number using the current system settings.
        Dim tmpFont As pdFont
        Set tmpFont = Fonts.GetMatchingUIFont(8!)
        
        'We have to perform a number of intermediary calculations, and note that *some* of these results get
        ' cached at class level (so that RedrawBackBuffer can use 'em).
        Dim minAllowableSize As Long, numBlocksAllowed As Long, numBlocksThisSize As Long
        Dim startAmount As Double
        
        'Further processing varies depending on the current ruler orientation.  (Vertical rulers display
        ' rotated text, so the way we measure and position their notches is slightly different.)
        If (m_Orientation = pdo_Horizontal) Then
            
            'We now need to figure out what scale to use for our rendering.  PD typically renders ruler
            ' strings up to 4-digits long; as such, we don't want individual ruler blocks that are less
            ' than GetWidthOfText("0000") wide, plus a bit of padding.
            minAllowableSize = tmpFont.GetWidthOfString("0000") * 2 + Interface.FixDPI(6)
            
            'To figure out which base-10 scale to use, we need to know how many "minAllowableSize" blocks we
            ' can fit into the current ruler area.
            numBlocksAllowed = bWidth \ minAllowableSize
            
            'We now want to find the scale that produces the closest result to numBlocksAllowed,
            ' without going over. (Like guesses on the "Price is Right".)  Start at 1 and multiply by 10 until
            ' we arrive at a satisfactory result.
            Dim xStart As Long, xEnd As Long, xStep As Long
            startAmount = 0.1
            
            Do
                startAmount = startAmount * 10#
                xStart = Int(m_imgCoordRectF.Left * (1# / startAmount)) * startAmount
                xEnd = Int(m_imgCoordRectF.Width * (1# / startAmount)) * startAmount
                numBlocksThisSize = CDbl(xEnd - xStart) / startAmount
            Loop While (numBlocksThisSize > numBlocksAllowed)
            
            'We now have a proper base-10 scaling factor for this run.  Use it to calculate starting and
            ' ending values for the interior notch rendering loop.
            m_Step = Int(startAmount)
            m_LoopStart = Int(m_imgCoordRectF.Left * (1# / startAmount)) * m_Step - m_Step
            m_LoopEnd = Int(m_imgCoordRectF.Width * (1# / startAmount)) * m_Step + m_Step
            m_Interval = 10
            
        'Vertical rulers
        Else
            
            'Vertical rulers require a specialized font object.  Create it just once, then cache the result.
            If (m_VerticalFont Is Nothing) Then
                Set m_VerticalFont = New pdFont
                m_VerticalFont.SetFontFace "@" & tmpFont.GetFontFace()
                m_VerticalFont.SetFontSize 8!
                If (Not m_VerticalFont.CreateFontObject(900)) Then PDDebug.LogAction "WARNING!  Vertical font failed!"
            End If
            
            'We now need to figure out what scale to use for our rendering.  PD typically renders ruler
            ' strings up to 4-digits long; as such, we don't want individual ruler blocks that are less
            ' than GetWidthOfText("0000") wide.  (Unlike the x-direction, note that we don't add artificial
            ' padding here; vertical text already includes a large amount of padding, due to hinting differences.)
            minAllowableSize = m_VerticalFont.GetWidthOfString("0000") * 2 - 8
            
            'To figure out which base-10 scale to use, we need to know how many "minAllowableSize" blocks we
            ' can fit into the current ruler area.
            numBlocksAllowed = bHeight \ minAllowableSize
            
            'We now want to find the scale that produces the closest result to numBlocksAllowed,
            ' without going over. (Like guesses on the "Price is Right".)  Start at 1 and multiply by 10 until
            ' we arrive at a satisfactory result.
            Dim yStart As Long, yEnd As Long, yStep As Long
            startAmount = 0.1
            
            Do
                startAmount = startAmount * 10#
                yStart = Int(m_imgCoordRectF.Top * (1# / startAmount)) * startAmount
                yEnd = Int(m_imgCoordRectF.Height * (1# / startAmount)) * startAmount
                numBlocksThisSize = CDbl(yEnd - yStart) / startAmount
            Loop While (numBlocksThisSize > numBlocksAllowed)
            
            'We now have a proper base-10 scaling factor for this run.  Use it to calculate starting and
            ' ending values for the interior notch rendering loop.
            m_Step = Int(startAmount)
            m_LoopStart = Int(m_imgCoordRectF.Top * (1# / startAmount)) * m_Step - m_Step
            m_LoopEnd = Int(m_imgCoordRectF.Height * (1# / startAmount)) * m_Step + m_Step
            m_Interval = 10
            
        End If
        
        'If possible, I also like to render text alongside other, intermediate numbers (e.g. not just
        ' powers of 10, but if there's room, every 2 or 5 values, also).  If room is available for
        ' also rendering one of these factors, use it.
        If ((numBlocksThisSize * 5) <= numBlocksAllowed) Then
            m_Step = m_Step \ 5
            m_Interval = 5
        ElseIf ((numBlocksThisSize * 2) <= numBlocksAllowed) Then
            m_Step = m_Step \ 2
            m_Interval = 2
        End If
        
        Set tmpFont = Nothing
        
    End If
    
    'No other special preparation is required for this control, so proceed with recreating the back buffer
    RedrawBackBuffer redrawImmediately
            
End Sub

'Use this function to completely redraw the back buffer from scratch.  Note that this is computationally expensive compared to just flipping the
' existing buffer to the screen, so only redraw the backbuffer if the control state has somehow changed.
Private Sub RedrawBackBuffer(Optional ByVal redrawImmediately As Boolean = False)
    
    If m_SuspendRedraws Then Exit Sub
    
    'Request the back buffer DC, and ask the support module to erase any existing rendering for us.
    Dim bufferDC As Long
    bufferDC = ucSupport.GetBackBufferDC(True, m_Colors.RetrieveColor(PDR_Background))
    If (bufferDC = 0) Then Exit Sub
    
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    'Rendering is pretty easy - fill a fraction of the control with the current progress level!
    Dim okToRender As Boolean
    okToRender = pdMain.IsProgramRunning() And ucSupport.AmIVisible() And (g_OpenImageCount > 0)
    If okToRender Then okToRender = (Not pdImages(g_CurrentImage) Is Nothing)
    If okToRender Then
        
        Dim cPainter As pd2DPainter
        Drawing2D.QuickCreatePainter cPainter
        
        Dim cSurface As pd2DSurface
        Drawing2D.QuickCreateSurfaceFromDC cSurface, bufferDC, False
        
        Dim cPen As pd2DPen
        Drawing2D.QuickCreateSolidPen cPen, 1!, m_Colors.RetrieveColor(PDR_Notch, Me.Enabled)
        
        Dim ctlRectF As RectF
        With ctlRectF
            .Top = 0!
            .Left = 0!
            .Width = bWidth - 1
            .Height = bHeight - 1
        End With
        
        Dim rulerFontColor As Long
        rulerFontColor = m_Colors.RetrieveColor(PDR_Text, Me.Enabled)
        
        'Regardless of ruler distance, we always draw midpoint notches
        Dim midPointNotch As Double, halfSize As Long, quarterSize As Long
        midPointNotch = m_Step / 2
        
        'TESTING ONLY: draw lines at every 100 px
        Dim x As Long, y As Long, i As Long, tmpStep As Double
        Dim xNew As Double, yNew As Double, xNewInt As Long, yNewInt As Long
        If (m_Orientation = pdo_Horizontal) Then
        
            'Start by drawing a full-width line across the bottom of the ruler
            cPainter.DrawLineI cSurface, cPen, 0, bHeight - 1, bWidth, bHeight - 1
            
            halfSize = bHeight * 0.4
            quarterSize = bHeight * 0.25
            
            Dim tmpFont As pdFont
            Set tmpFont = Fonts.GetMatchingUIFont(8!)
            tmpFont.SetFontColor rulerFontColor
            tmpFont.SetTextAlignment vbLeftJustify
            tmpFont.AttachToDC bufferDC
            
            For x = m_LoopStart To m_LoopEnd Step m_Step
                
                'Convert this "hypothetical" coordinate from image space to canvas coordinate space
                Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), x, 0, xNew, yNew
                xNewInt = Int(xNew + m_CanvasOffsetX + 0.5)
                
                'Render this line, and position text to the right of it
                cPainter.DrawLineI cSurface, cPen, xNewInt, 0, xNewInt, bHeight
                tmpFont.FastRenderText xNewInt + 3, -1, CStr(x)
                
                'Next, draw midpoint notches.  Which notches we draw varies based on the current interval.
                ' The default interval setting is base-10 (e.g. 0, 1, 2 or 0, 100, 200).  In this setting,
                ' we want to draw *9* intermediary notches.
                If (m_Interval = 10) Then
                    
                    For i = 1 To 9
                        Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), x + (m_Step * 0.1) * i, 0, xNew, yNew
                        xNewInt = Int(xNew + m_CanvasOffsetX + 0.5)
                        If ((i And &H1) = 0) Then
                            cPainter.DrawLineI cSurface, cPen, xNewInt, bHeight - halfSize, xNewInt, bHeight
                        Else
                            cPainter.DrawLineI cSurface, cPen, xNewInt, bHeight - quarterSize, xNewInt, bHeight
                        End If
                    Next i
                
                'When the interval is 2, it means that every *base-2* value renders text (e.g. 0, 2, 4, 6).
                ' We want render three points, with the midpoint being drawn slightly larger than the other two.
                ElseIf (m_Interval = 5) Then
                
                    For i = 1 To 3
                        Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), x + (m_Step * 0.25) * i, 0, xNew, yNew
                        xNewInt = Int(xNew + m_CanvasOffsetX + 0.5)
                        If (i = 2) Then
                            cPainter.DrawLineI cSurface, cPen, xNewInt, bHeight - halfSize, xNewInt, bHeight
                        Else
                            cPainter.DrawLineI cSurface, cPen, xNewInt, bHeight - quarterSize, xNewInt, bHeight
                        End If
                    Next i
                
                'When the interval is 2, it means that every *base-5* value renders text (e.g. 0, 5, 10).
                ' We want to draw four small notches for intermediary values.
                ElseIf (m_Interval = 2) Then
                    For i = 1 To 4
                        Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), x + (m_Step * 0.2) * i, 0, xNew, yNew
                        xNewInt = Int(xNew + m_CanvasOffsetX + 0.5)
                        cPainter.DrawLineI cSurface, cPen, xNewInt, bHeight - quarterSize, xNewInt, bHeight
                    Next i
                End If
                
            Next x
            
            tmpFont.ReleaseFromDC
            Set tmpFont = Nothing
            
        Else
            
            'Start by drawing a full-height line across the right of the ruler
            cPainter.DrawLineI cSurface, cPen, bWidth - 1, 0, bWidth - 1, bHeight
            
            halfSize = bWidth * 0.4
            quarterSize = bWidth * 0.25
            
            'Vertical fonts are rendered using a special font object.
            If (Not m_VerticalFont Is Nothing) Then
                
                m_VerticalFont.SetFontColor rulerFontColor
                m_VerticalFont.SetTextAlignment vbLeftJustify
                m_VerticalFont.AttachToDC bufferDC
                    
                For y = m_LoopStart To m_LoopEnd Step m_Step
                
                    'Convert this "hypothetical" coordinate from image space to canvas coordinate space
                    Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), 0, y, xNew, yNew
                    yNewInt = Int(yNew + m_CanvasOffsetY + 0.5)
                    
                    'Render this line, and position text to the right of it
                    cPainter.DrawLineI cSurface, cPen, 0, yNewInt, bWidth, yNewInt
                    m_VerticalFont.FastRenderText -4, yNewInt + 3 + m_VerticalFont.GetWidthOfString(CStr(y)), CStr(y)
                    
                    'Next, draw midpoint notches.  Which notches we draw varies based on the current interval.
                    ' The default interval setting is base-10 (e.g. 0, 1, 2 or 0, 100, 200).  In this setting,
                    ' we want to draw *9* intermediary notches.
                    If (m_Interval = 10) Then
                        
                        For i = 1 To 9
                            Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), 0, y + (m_Step * 0.1) * i, xNew, yNew
                            yNewInt = Int(yNew + m_CanvasOffsetY + 0.5)
                            If ((i And &H1) = 0) Then
                                cPainter.DrawLineI cSurface, cPen, bWidth - halfSize, yNewInt, bWidth, yNewInt
                            Else
                                cPainter.DrawLineI cSurface, cPen, bWidth - quarterSize, yNewInt, bWidth, yNewInt
                            End If
                        Next i
                    
                    'When the interval is 2, it means that every *base-2* value renders text (e.g. 0, 2, 4, 6).
                    ' We want render three points, with the midpoint being drawn slightly larger than the other two.
                    ElseIf (m_Interval = 5) Then
                    
                        For i = 1 To 3
                            Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), 0, y + (m_Step * 0.25) * i, xNew, yNew
                            yNewInt = Int(yNew + m_CanvasOffsetY + 0.5)
                            If (i = 2) Then
                                cPainter.DrawLineI cSurface, cPen, bWidth - halfSize, yNewInt, bWidth, yNewInt
                            Else
                                cPainter.DrawLineI cSurface, cPen, bWidth - quarterSize, yNewInt, bWidth, yNewInt
                            End If
                        Next i
                    
                    'When the interval is 2, it means that every *base-5* value renders text (e.g. 0, 5, 10).
                    ' We want to draw four small notches for intermediary values.
                    ElseIf (m_Interval = 2) Then
                        For i = 1 To 4
                            Drawing.ConvertImageCoordsToCanvasCoords FormMain.MainCanvas(0), pdImages(g_CurrentImage), 0, y + (m_Step * 0.2) * i, xNew, yNew
                            yNewInt = Int(yNew + m_CanvasOffsetY + 0.5)
                            cPainter.DrawLineI cSurface, cPen, bWidth - quarterSize, yNewInt, bWidth, yNewInt
                        Next i
                    End If
                    
                Next y
                    
                m_VerticalFont.ReleaseFromDC
                
            'Failsafe for font object existing
            End If
        
        End If
        
        'Finally, render the current mouse position
        cPen.SetPenColor m_Colors.RetrieveColor(PDR_Mouse, Me.Enabled)
        
        'We already know the mouse coordinates in both canvas and image space.  Use the canvas space plus the
        ' modifiers calculated by UpdateControlLayout (which describe the difference between our top/left values
        ' and the canvas's top/left values).
        Dim drawPosX1 As Single, drawPosX2 As Single, drawPosY1 As Single, drawPosY2 As Single
        If (m_Orientation = pdo_Horizontal) Then
            drawPosX1 = m_MouseCanvasX + m_CanvasOffsetX
            drawPosX2 = drawPosX1
            drawPosY1 = 0
            drawPosY2 = bHeight - 1
        Else
            drawPosY1 = m_MouseCanvasY + m_CanvasOffsetY
            drawPosY2 = drawPosY1
            drawPosX1 = 0
            drawPosX2 = bWidth - 1
        End If
        
        'Finally, draw the mouse line *twice*.  First, draw it as a 3px wide, mostly translucent line.
        ' Then, follow it up with a crisp, opaque, 1px line over the top.  This gives it a very slight
        ' "glow" effect without visually obscuring where the mouse position accurately lies (lays? idk).
        cPen.SetPenOpacity 25!
        cPen.SetPenWidth 3!
        cPainter.DrawLineF cSurface, cPen, drawPosX1, drawPosY1, drawPosX2, drawPosY2
        cPen.SetPenOpacity 100!
        cPen.SetPenWidth 1!
        cPainter.DrawLineF cSurface, cPen, drawPosX1, drawPosY1, drawPosX2, drawPosY2
        
        Set cPen = Nothing: Set cSurface = Nothing: Set cPainter = Nothing
        
    End If
    
    'Paint the final result to the screen, as relevant
    ucSupport.RequestRepaint redrawImmediately
    If (Not pdMain.IsProgramRunning()) Then UserControl.Refresh
    
End Sub

'Before this control does any painting, we need to retrieve relevant colors from PD's primary theming class.  Note that this
' step must also be called if/when PD's visual theme settings change.
Private Sub UpdateColorList()
    With m_Colors
        .LoadThemeColor PDR_Background, "Background", IDE_WHITE
        .LoadThemeColor PDR_Text, "Text", IDE_BLACK
        .LoadThemeColor PDR_Notch, "Notch", IDE_BLACK
        .LoadThemeColor PDR_Mouse, "Mouse", IDE_BLUE
    End With
End Sub

'External functions can call this to request a redraw.  This is helpful for live-updating theme settings, as in the Preferences dialog.
Public Sub UpdateAgainstCurrentTheme(Optional ByVal hostFormhWnd As Long = 0)
    If ucSupport.ThemeUpdateRequired Then
        UpdateColorList
        If pdMain.IsProgramRunning() Then ucSupport.UpdateAgainstThemeAndLanguage
    End If
End Sub

'By design, PD prefers to not use design-time tooltips.  Apply tooltips at run-time, using this function.
' (IMPORTANT NOTE: translations are handled automatically.  Always pass the original English text!)
Public Sub AssignTooltip(ByRef newTooltip As String, Optional ByRef newTooltipTitle As String = vbNullString, Optional ByVal newTooltipIcon As TT_ICON_TYPE = TTI_NONE, Optional ByVal raiseTipsImmediately As Boolean = False)
    ucSupport.AssignTooltip UserControl.ContainerHwnd, newTooltip, newTooltipTitle, newTooltipIcon, raiseTipsImmediately
End Sub
