//
//  ScalingHeaderScrollView.swift
//  ScalingHeaderScrollView
//
//  Created by Alisa Mylnikova on 16/09/2021.
//  Copyright © 2021 Exyte. All rights reserved.
//

import SwiftUI
import SwiftUIIntrospect

public enum SnapHeaderState: Equatable {
    case expanded
    case collapsed
    case custom(CGFloat)
}

public enum SnapHeaderMode: Int {
    /// Disable header snap.
    case disabled

    /// Enable header snap.
    /// Once you lift your finger header snaps either to min or max height automatically.
    case immediately

    /// Enable header snap. Smoother scroll mode.
    /// At the end of scroll view deceleration the header snaps either to min or max height automatically.
    case afterFinishAccelerating
}

public struct ScalingHeaderScrollView<Header: View, Content: View>: View {

    /// Content on the top, which will be collapsed
    public var header: Header

    /// Content on the bottom
    public var content: Content

    /// Should the progress view be showing or not, when "pull to refresh" action
    @State private var pullToRefreshInProgress: Bool = false

    /// Should show the progress view during "pull to load more" action
    @State private var pullToLoadMoreInProgress: Bool = false

    /// UIKit's UIScrollView
    private var uiScrollView: UIScrollView? { scrollViewDelegate.uiScrollView }

    /// Sets the opacity value for pull-to-load-more progress view
    @State private var pullToLoadOpacity: CGFloat = 1.0

    /// Sets the opacity value for pull-to-refresh progress view
    @State private var pullToRefreshOpacity: CGFloat = 1.0

    /// Scroll view acceleration value. It's set in the scroll mode, when user about to end dragging
    @State private var acceleration: Double = 0

    /// UIScrollView delegate, needed for calling didPullToRefresh or didEndDragging
    @StateObject private var scrollViewDelegate = ScalingHeaderScrollViewDelegate()

    /// ScrollView's content frame, needed for calculation of frame changing
    @StateObject private var contentFrame = ViewFrame()

    /// Interpolation from 0 to 1 of current collapse progress
    @Binding private var progress: CGFloat

    /// Current scroll offset Y value
    @Binding private var scrollOffset: CGFloat

    /// Automatically sets to true, if pull to refresh is triggered. Manually set to false to hide loading indicator.
    @Binding private var isLoading: Bool

    /// Set to true to immediately scroll to top
    @Binding private var scrollToTop: Bool

    /// Use this variable to programmatically change header's visibility state
    @Binding private var shouldSnapTo: SnapHeaderState?

    /// 用于控制内容的滚动位置
    @Binding private var contentScrollPosition: CGFloat?

    /// 是否使用动画
    private var animateScroll: Bool = true

    /// Scroll view did reach bottom
    private var didReachBottom: (() -> Void)?

    /// Called once pull to refresh is triggered
    private var didPullToRefresh: (() -> Void)?

    /// Called once pull to load more is triggered
    private var didPullToLoadMore: (() -> Void)?

    /// Height for uncollapsed state
    private var maxHeight: CGFloat = 350.0

    /// Height for collapsed state
    private var minHeight: CGFloat = 150.0

    /// Allow collapsing while scrolling up
    private var allowsHeaderCollapseFlag: Bool = false

    /// Animation, when header size will be changed
    private var headerAnimation: Animation?

    /// Allow enlarging while pulling down
    private var allowsHeaderGrowthFlag: Bool = false

    /// Use this variable to set the padding value of the content from the edge when pull-to-load is active
    private var pullToLoadMoreContentOffset: CGFloat = 0.0

    /// Shows or hides the indicator for the scrollView
    private var showsIndicators: Bool = true

    /// Allow force snap to closest position after lifting the finger, i.e. forbid to be left in unfinished state
    /// Specify any amount of values in 0...1 to set snapping points, 0 - fully collapsed header, 1 - fully expanded
    private var headerSnappingPositions: [CGFloat] = []

    /// Flag whether the snapping should wait until scrolling has finished accelerating
    private var headerSnappingShouldWaitFinishAccelerating: Bool = false

    /// Use this to set initial scroll position to anything other than fully expanded
    /// Set a value in 0...1, 0 - fully collapsed header, 1 - fully expanded
    private var initialSnapPosition: CGFloat?

    /// Alignment for header content
    private var headerAlignment: Alignment = .center

    /// Clipped or not header
    private var headerIsClipped: Bool = true

    /// Private computed properties
    private var hasPullToRefresh: Bool {
        didPullToRefresh != nil
    }

    private var hasPullToLoadMore: Bool {
        didPullToLoadMore != nil
    }

    private var contentOffset: CGFloat {
        isLoading && pullToRefreshInProgress ? maxHeight + 32 : pullToLoadMoreContentOffsetValue
    }

    private var pullToLoadMoreContentOffsetValue: CGFloat {
        isLoading && pullToLoadMoreInProgress ? maxHeight - pullToLoadMoreContentOffset : maxHeight
    }

    private var progressViewOffset: CGFloat {
        isLoading ? maxHeight + 24.0 : maxHeight
    }

    /// height for header: reduced if reducing is allowed, or fixed if not
    private var headerHeight: CGFloat {
        allowsHeaderCollapseFlag ? getHeightForHeaderView() : maxHeight
    }

    /// Scaling for header: to enlarge while pulling down
    private var headerScaleOnPullDown: CGFloat {
        !hasPullToRefresh && allowsHeaderGrowthFlag ? fmax(1.0, getHeightForHeaderView() / maxHeight * 0.9) : 1.0
    }

    private var showPullToRefreshProgress: Bool {
        hasPullToRefresh && (isLoading && pullToRefreshInProgress)
    }

    private var showPullToLoadMoreProgress: Bool {
        hasPullToLoadMore && (isLoading && pullToLoadMoreInProgress)
    }

    // MARK: - Init

    public init(@ViewBuilder header: @escaping () -> Header,
                @ViewBuilder content: @escaping () -> Content,
                contentScrollPosition: Binding<CGFloat?> = .constant(nil)) {
        self.header = header()
        self.content = content()
        _progress = .constant(0)
        _scrollOffset = .constant(0)
        _isLoading = .constant(false)
        _scrollToTop = .constant(false)
        _shouldSnapTo = .constant(nil)
        _contentScrollPosition = contentScrollPosition
    }

    // MARK: - Body builder

    public var body: some View {
        GeometryReader { globalGeometry in
            if #available(iOS 26.0, *) {
                scrollViewWithOnScrollGeometryChange(globalGeometry: globalGeometry)
            } else {
                scrollViewWithIntrospect(globalGeometry: globalGeometry)
            }

            if showPullToLoadMoreProgress {
                progressView
                    .opacity(pullToLoadOpacity)
                    .offset(y: globalGeometry.size.height - 60)
            }
        }
    }

    // MARK: - iOS 18+ 新实现 (使用 onScrollGeometryChange)
    @available(iOS 18.0, *)
    @ViewBuilder
    private func scrollViewWithOnScrollGeometryChange(globalGeometry: GeometryProxy) -> some View {
        ScrollView(showsIndicators: showsIndicators) {
            content
                .offset(y: contentOffset)
                .frameGetter($contentFrame.frame)
                .onChange(of: contentFrame.frame) { frame in
                    pullToRefreshInProgress = frame.minY - globalGeometry.frame(in: .global).minY > 20.0
                    
                    // 处理 pull-to-refresh 回调
                    if pullToRefreshInProgress && !isLoading {
                        if let didPullToRefresh = didPullToRefresh {
                            pullToLoadMoreInProgress = false
                            pullToRefreshInProgress = true
                            withAnimation { isLoading = true }
                            didPullToRefresh()
                        }
                    }
                }
                .onChange(of: scrollToTop) { value in
                    if value {
                        scrollToTop = false
                        // iOS 18 使用 ScrollView 的 scrollTo
                        withAnimation {
                            scrollOffset = 0
                        }
                    }
                }
                .onChange(of: shouldSnapTo) { value in
                    if let value = value {
                        shouldSnapTo = nil
                        setScrollPositionForIOS26(value)
                    }
                }
            GeometryReader { scrollGeometry in
                ZStack(alignment: .topLeading) {
                    if showPullToRefreshProgress {
                        progressView
                            .opacity(pullToRefreshOpacity)
                            .offset(y: getOffsetForHeaderWithOffset(-scrollOffset) + progressViewOffset)
                    }
                    header
                        .frame(height: allowsHeaderCollapseFlag ? getHeightForHeaderViewWithOffset(-scrollOffset) : maxHeight, alignment: headerAlignment)
                        .clipped(isClipped: headerIsClipped)
                        .contentShape(Rectangle())
                        .offset(y: getOffsetForHeaderWithOffset(-scrollOffset))
                        .allowsHitTesting(true)
                        .scaleEffect(!hasPullToRefresh && allowsHeaderGrowthFlag ? fmax(1.0, getHeightForHeaderViewWithOffset(-scrollOffset) / maxHeight * 0.9) : 1.0)
                }
                .offset(y: getGeometryReaderVsScrollViewWithOffset(scrollGeometry: scrollGeometry, globalGeometry: globalGeometry, offset: -scrollOffset))
            }
            .background(Color.clear)
            .frame(height: maxHeight)
            .offset(y: -(contentFrame.startingRect?.maxY ?? UIScreen.main.bounds.height))
        }
        .animation(headerAnimation, value: shouldSnapTo)
        .onScrollGeometryChange(for: ScrollData.self) { geometry in
            ScrollData(
                contentOffset: geometry.contentOffset,
                contentSize: geometry.contentSize,
                containerSize: geometry.containerSize
            )
        } action: { oldValue, newValue in
            let offset = newValue.contentOffset.y
            self.progress = getCollapseProgressWithOffset(offset)
            self.scrollOffset = -offset
            
            // 处理 pull-to-load-more 回调
            let maxYOffset = newValue.contentSize.height - newValue.containerSize.height
            if -offset >= maxYOffset && !isLoading {
                if let didPullToLoadMore = didPullToLoadMore {
                    pullToLoadMoreInProgress = true
                    pullToRefreshInProgress = false
                    withAnimation { isLoading = true }
                    didPullToLoadMore()
                }
            }
            
            // 处理 didReachBottom 回调
            if -offset >= maxYOffset {
                didReachBottom?()
            }
            
            withAnimation {
                pullToRefreshOpacity = -(-offset) > 32.0 ? 0.0 : 1.0
                pullToLoadOpacity = -(-offset) < maxYOffset ? 0.0 : 1.0
            }
            
            // 处理 header snapping (模拟 didEndDragging)
            handleHeaderSnappingForIOS26(offset: offset)
        }
        .onAppear {
            snapInitialScrollPositionForIOS26()
        }
    }

    // MARK: - iOS 17 及以下 (使用 SwiftUIIntrospect)
    @ViewBuilder
    private func scrollViewWithIntrospect(globalGeometry: GeometryProxy) -> some View {
        ScrollView(showsIndicators: showsIndicators) {
            content
                .offset(y: contentOffset)
                .frameGetter($contentFrame.frame)
                .onChange(of: contentFrame.frame) { frame in
                    pullToRefreshInProgress = frame.minY - globalGeometry.frame(in: .global).minY > 20.0
                }
                .onChange(of: scrollToTop) { value in
                    if value {
                        scrollToTop = false
                        setScrollPositionTo(.expanded)
                    }
                }
                .onChange(of: shouldSnapTo) { value in
                    if let value = value {
                        shouldSnapTo = nil
                        setScrollPositionTo(value)
                    }
                }
            GeometryReader { scrollGeometry in
                ZStack(alignment: .topLeading) {
                    if showPullToRefreshProgress {
                        progressView
                            .opacity(pullToRefreshOpacity)
                            .offset(y: getOffsetForHeader() + progressViewOffset)
                    }
                    header
                        .frame(height: headerHeight, alignment: headerAlignment)
                        .clipped(isClipped: headerIsClipped)
                        .contentShape(Rectangle())
                        .offset(y: getOffsetForHeader())
                        .allowsHitTesting(true)
                        .scaleEffect(headerScaleOnPullDown)
                }
                .offset(y: getGeometryReaderVsScrollView(scrollGeometry: scrollGeometry, globalGeometry: globalGeometry))
            }
            .background(Color.clear)
            .frame(height: maxHeight)
            .offset(y: -(contentFrame.startingRect?.maxY ?? UIScreen.main.bounds.height))
        }
        .animation(headerAnimation, value: shouldSnapTo)
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18)) { scrollView in
            configure(scrollView: scrollView)
        }
        .onAppear {
            snapInitialScrollPosition()
        }
    }

    // MARK: - Private Views

    private var progressView: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .frame(width: UIScreen.main.bounds.width, height: getHeightForLoadingView())
            .scaleEffect(1.25)
    }

    // MARK: - Private configure

    private func configure(scrollView: UIScrollView) {
        scrollView.delegate = scrollViewDelegate

        // 添加这段代码
        if let position = contentScrollPosition {
            DispatchQueue.main.async {
                scrollView.setContentOffset(CGPoint(x: 0, y: position), animated: self.animateScroll)
                self.contentScrollPosition = nil  // 重置，避免重复滚动
            }
        }

        if let didPullToRefresh = didPullToRefresh {
            scrollViewDelegate.didPullToRefresh = {
                pullToLoadMoreInProgress = false
                pullToRefreshInProgress = true
                withAnimation { isLoading = true }
                didPullToRefresh()
            }
        }
        if let didPullToLoadMore = didPullToLoadMore {
            scrollViewDelegate.didPullToLoadMore = {
                pullToLoadMoreInProgress = true
                pullToRefreshInProgress = false
                withAnimation { isLoading = true }
                didPullToLoadMore()
            }
        }
        scrollViewDelegate.didScroll = {
            DispatchQueue.main.async {
                self.progress = getCollapseProgress()
                self.scrollOffset = -getScrollOffset()
                withAnimation {
                    pullToRefreshOpacity = -getScrollOffset() > 32.0 ? 0 : 1
                    pullToLoadOpacity = -getScrollOffset() < getMaxYOffset() ? 0 : 1
                }
            }
        }
        scrollViewDelegate.didEndDragging = {
            guard !headerSnappingPositions.isEmpty else { return }

            // if waiting for acceleration to complete is disabled or if acceleration is very slow
            if !headerSnappingShouldWaitFinishAccelerating || fabs(acceleration) < 0.2 {
                snapScrollPosition()
            }
        }

        scrollViewDelegate.didReachBottom = {
            didReachBottom?()
        }

        scrollViewDelegate.willEndDragging = { acceleration in
            if headerSnappingShouldWaitFinishAccelerating {
                self.acceleration = acceleration
            }
        }

        scrollViewDelegate.didEndDecelerating = {
            if headerSnappingShouldWaitFinishAccelerating && !headerSnappingPositions.isEmpty {
                snapScrollPosition()
            }
        }

        DispatchQueue.main.async {
            if uiScrollView != scrollView {
                scrollViewDelegate.uiScrollView = scrollView
                snapInitialScrollPosition()
            }
        }
    }

    // MARK: - Private actions

    private func setScrollPositionTo(_ state: SnapHeaderState) {
        guard var contentOffset = uiScrollView?.contentOffset else { return }
        switch state {
        case .expanded:
            contentOffset.y = 0
        case .collapsed:
            contentOffset.y = maxHeight - minHeight
        case .custom(let value):
            contentOffset.y = maxHeight - minHeight + value
        }
        uiScrollView?.setContentOffset(contentOffset, animated: true)
    }

    private func snapScrollPosition() {
        guard var contentOffset = uiScrollView?.contentOffset else { return }

        let extraSpace: CGFloat = maxHeight - minHeight
        let offset = contentOffset.y
        for i in 0..<headerSnappingPositions.count - 1 {
            let first = headerSnappingPositions[i] * extraSpace
            let second = headerSnappingPositions[i+1] * extraSpace
            if offset > first, offset < second {
                let result: CGFloat
                if (offset - first) < (second - offset) { // closer to first point
                    result = first
                } else {
                    result = second
                }
                contentOffset.y = result
                uiScrollView?.setContentOffset(contentOffset, animated: true)
                return
            }
        }
    }

    private func snapInitialScrollPosition() {
        if let initialSnapPosition = initialSnapPosition {
            guard var contentOffset = uiScrollView?.contentOffset else { return }
            let extraSpace: CGFloat = maxHeight - minHeight
            contentOffset.y = initialSnapPosition * extraSpace
            uiScrollView?.setContentOffset(contentOffset, animated: true)
        }
    }

    // MARK: - Private getters for heights and offsets (原有方法，用于 SwiftUIIntrospect)

    private func getScrollOffset() -> CGFloat {
        -(uiScrollView?.contentOffset.y ?? 0)
    }

    private func getMaxYOffset() -> CGFloat {
        (uiScrollView?.contentSize.height ?? 0.0) - (uiScrollView?.bounds.height ?? 0.0)
    }

    private func getContentHeight() -> CGFloat {
        uiScrollView?.contentSize.height ?? 0.0
    }

    private func getGeometryReaderVsScrollView(scrollGeometry: GeometryProxy, globalGeometry: GeometryProxy) -> CGFloat {
        getScrollOffset() - scrollGeometry.frame(in: .global).minY + globalGeometry.frame(in: .global).minY
    }

    private func getOffsetForHeader() -> CGFloat {
        let offset = getScrollOffset()
        let extraSpace = maxHeight - minHeight

        if offset < -extraSpace {
            let imageOffset = abs(fmin(-extraSpace, offset))
            return allowsHeaderCollapseFlag ? imageOffset : (minHeight - maxHeight) - offset
        } else if offset > 0 {
            return -offset
        }
        return maxHeight - headerHeight
    }

    private func getHeightForHeaderView() -> CGFloat {
        let offset = getScrollOffset()
        if hasPullToRefresh {
            return fmin(fmax(minHeight, maxHeight + offset), maxHeight)
        } else {
            return fmax(minHeight, maxHeight + offset)
        }
    }

    private func getCollapseProgress() -> CGFloat {
        1 - fmin(fmax((getHeightForHeaderView() - minHeight) / (maxHeight - minHeight), 0), 1)
    }

    private func getHeightForLoadingView() -> CGFloat {
        fmax(0, getScrollOffset())
    }

    // MARK: - 新增方法，用于 onScrollGeometryChange

    @available(iOS 18.0, *)
    private func getMaxYOffsetWithGeometry(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height - geometry.containerSize.height
    }

    @available(iOS 18.0, *)
    private func getGeometryReaderVsScrollViewWithOffset(scrollGeometry: GeometryProxy, globalGeometry: GeometryProxy, offset: CGFloat) -> CGFloat {
        offset - scrollGeometry.frame(in: .global).minY + globalGeometry.frame(in: .global).minY
    }

    @available(iOS 18.0, *)
    private func getOffsetForHeaderWithOffset(_ offset: CGFloat) -> CGFloat {
        let extraSpace = maxHeight - minHeight

        if offset < -extraSpace {
            let imageOffset = abs(fmin(-extraSpace, offset))
            return allowsHeaderCollapseFlag ? imageOffset : (minHeight - maxHeight) - offset
        } else if offset > 0 {
            return -offset
        }
        return maxHeight - (allowsHeaderCollapseFlag ? getHeightForHeaderViewWithOffset(offset) : maxHeight)
    }

    @available(iOS 18.0, *)
    private func getHeightForHeaderViewWithOffset(_ offset: CGFloat) -> CGFloat {
        if hasPullToRefresh {
            return fmin(fmax(minHeight, maxHeight + offset), maxHeight)
        } else {
            return fmax(minHeight, maxHeight + offset)
        }
    }

    @available(iOS 18.0, *)
    private func getCollapseProgressWithOffset(_ offset: CGFloat) -> CGFloat {
        1 - fmin(fmax((getHeightForHeaderViewWithOffset(offset) - minHeight) / (maxHeight - minHeight), 0), 1)
    }

    /// iOS 18 专用的状态变量
    @State private var lastScrollOffset: CGFloat = 0
    @State private var scrollVelocity: CGFloat = 0
    @State private var isScrolling: Bool = false
    @State private var scrollEndTimer: Timer?

    // MARK: - iOS 18 专用的辅助方法

    @available(iOS 18.0, *)
    private func setScrollPositionForIOS26(_ state: SnapHeaderState) {
        withAnimation {
            switch state {
            case .expanded:
                scrollOffset = 0
            case .collapsed:
                scrollOffset = -(maxHeight - minHeight)
            case .custom(let value):
                scrollOffset = -(maxHeight - minHeight + value)
            }
        }
    }

    @available(iOS 18.0, *)
    private func snapInitialScrollPositionForIOS26() {
        if let initialSnapPosition = initialSnapPosition {
            let extraSpace: CGFloat = maxHeight - minHeight
            let targetOffset = -(initialSnapPosition * extraSpace)
            withAnimation {
                scrollOffset = targetOffset
            }
        }
    }

    @available(iOS 18.0, *)
    private func handleHeaderSnappingForIOS26(offset: CGFloat) {
        guard !headerSnappingPositions.isEmpty else { return }
        
        // 计算滚动速度
        let currentOffset = -offset
        scrollVelocity = currentOffset - lastScrollOffset
        lastScrollOffset = currentOffset
        
        // 检测滚动是否结束（模拟 didEndDragging + didEndDecelerating）
        if abs(scrollVelocity) > 0.1 {
            isScrolling = true
            scrollEndTimer?.invalidate()
            scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                if abs(self.scrollVelocity) < 0.1 {
                    self.isScrolling = false
                    self.snapScrollPositionForIOS26(currentOffset: currentOffset)
                }
            }
        }
    }

    @available(iOS 18.0, *)
    private func snapScrollPositionForIOS26(currentOffset: CGFloat) {
        let extraSpace: CGFloat = maxHeight - minHeight
        let offset = currentOffset
        
        for i in 0..<headerSnappingPositions.count - 1 {
            let first = headerSnappingPositions[i] * extraSpace
            let second = headerSnappingPositions[i+1] * extraSpace
            if offset > first, offset < second {
                let result: CGFloat
                if (offset - first) < (second - offset) {
                    result = first
                } else {
                    result = second
                }
                withAnimation {
                    scrollOffset = -result
                }
                return
            }
        }
    }
}

// MARK: - Extension View

extension View {

    @ViewBuilder
    func clipped(isClipped: Bool) -> some View {
        if isClipped {
            self.clipped()
        } else {
            self
        }
    }
}

// MARK: - Modifiers

extension ScalingHeaderScrollView {

    /// 设置内容的滚动位置
    public func setContentScrollPosition(_ position: Binding<CGFloat?>, animated: Bool = true) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView._contentScrollPosition = position
        scalingHeaderScrollView.animateScroll = animated
        return scalingHeaderScrollView
    }

    /// Passes current collapse progress value into progress binding
    public func collapseProgress(_ progress: Binding<CGFloat>) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView._progress = progress
        return scalingHeaderScrollView
    }

    /// Passes current scroll offset value into binding
    public func scrollOffset(_ scrollOffset: Binding<CGFloat>) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView._scrollOffset = scrollOffset
        return scalingHeaderScrollView
    }

    /// Process the position when scroll view did reach bottom
    public func scrollViewDidReachBottom(perform: @escaping () -> Void) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.didReachBottom = perform
        return scalingHeaderScrollView
    }

    /// Allows to set up callback and `isLoading` state for pull-to-refresh action
    public func pullToRefresh(isLoading: Binding<Bool>, perform: @escaping () -> Void) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView._isLoading = isLoading
        scalingHeaderScrollView.didPullToRefresh = perform
        return scalingHeaderScrollView
    }

    /// Allows to set up callback and `isLoading` state for pull-to-load-more action
    public func pullToLoadMore(isLoading: Binding<Bool>, contentOffset: CGFloat, perform: @escaping () -> Void) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView._isLoading = isLoading
        scalingHeaderScrollView.pullToLoadMoreContentOffset = contentOffset
        scalingHeaderScrollView.didPullToLoadMore = perform
        return scalingHeaderScrollView
    }

    /// Allows content scroll reset, need to change Binding to `true`
    public func scrollToTop(resetScroll: Binding<Bool>) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView._scrollToTop = resetScroll
        return scalingHeaderScrollView
    }

    /// Changing the size of the header at the moment
    public func snapHeaderToState(_ state: Binding<SnapHeaderState?>, animated: Bool = true) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.headerAnimation = animated ? .default : nil
        scalingHeaderScrollView._shouldSnapTo = state
        return scalingHeaderScrollView
    }

    /// Changes min and max heights of Header
    public func height(min: CGFloat = 150.0, max: CGFloat = 350.0) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.minHeight = min
        scalingHeaderScrollView.maxHeight = max
        return scalingHeaderScrollView
    }

    /// When scrolling up - switch between actual header collapse and simply moving it up
    public func allowsHeaderCollapse(_ allows: Bool = true) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.allowsHeaderCollapseFlag = allows
        return scalingHeaderScrollView
    }

    /// When scrolling down - enable/disable header scale
    public func allowsHeaderGrowth(_ allows: Bool = true) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.allowsHeaderGrowthFlag = allows
        return scalingHeaderScrollView
    }

    /// Enable header snap (once you lift your finger header snaps either to min or max height automatically)
    @available(*, deprecated, message: "Use `setHeaderSnapMode()` instead. Will be removed in future releases.")
    public func allowsHeaderSnap() -> ScalingHeaderScrollView {
        setHeaderSnapMode(.immediately)
    }

    /// Enable/disable header snap with snap mode selection
    /// - Parameter mode: Options for modes. Details see in ``SnapHeaderMode``
    /// - SeeAlso: ``SnapHeaderMode``
    public func setHeaderSnapMode(_ mode: SnapHeaderMode) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        switch mode {
        case .disabled:
            scalingHeaderScrollView.headerSnappingPositions = []
            scalingHeaderScrollView.headerSnappingShouldWaitFinishAccelerating = false
        case .immediately:
            if scalingHeaderScrollView.headerSnappingPositions.isEmpty {
                scalingHeaderScrollView.headerSnappingPositions = [0, 1]
            }
            scalingHeaderScrollView.headerSnappingShouldWaitFinishAccelerating = false
        case .afterFinishAccelerating:
            if scalingHeaderScrollView.headerSnappingPositions.isEmpty {
                scalingHeaderScrollView.headerSnappingPositions = [0, 1]
            }
            scalingHeaderScrollView.headerSnappingShouldWaitFinishAccelerating = true
        }
        return scalingHeaderScrollView
    }

    /// Set positions for header snap (once you lift your finger header snaps to closest allowed position)
    public func headerSnappingPositions(snapPositions: [CGFloat]) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.headerSnappingPositions = snapPositions
        return scalingHeaderScrollView
    }

    /// Use this to set initial scroll position to anything other than fully expanded
    public func initialSnapPosition(initialSnapPosition: CGFloat) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.initialSnapPosition = initialSnapPosition
        return scalingHeaderScrollView
    }

    /// Hides scroll indicators
    public func hideScrollIndicators(_ hide: Bool = false) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.showsIndicators = hide
        return scalingHeaderScrollView
    }

    /// Header clipped
    public func headerIsClipped(_ isClipped: Bool = true) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.headerIsClipped = isClipped
        return scalingHeaderScrollView
    }

    /// Header alignment
    public func headerAlignment(_ alignment: Alignment) -> ScalingHeaderScrollView {
        var scalingHeaderScrollView = self
        scalingHeaderScrollView.headerAlignment = alignment
        return scalingHeaderScrollView
    }
}

// 添加这个结构体来传递滚动数据
@available(iOS 18.0, *)
private struct ScrollData: Equatable {
    let contentOffset: CGPoint
    let contentSize: CGSize
    let containerSize: CGSize
}
