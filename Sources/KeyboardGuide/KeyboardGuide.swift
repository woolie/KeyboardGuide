//
//  KeyboardGuide.swift
//  KeyboardGuide
//
//  Created by Yoshimasa Niwa on 2/18/20.
//  Copyright © 2020 Yoshimasa Niwa. All rights reserved.
//

import Foundation
import ObjectiveC
import UIKit

@objc(KBGKeyboardGuideObserver)
public protocol KeyboardGuideObserver {
    @objc
    func keyboardGuide(_ keyboardGuide: KeyboardGuide, didChangeDockedKeyboardState dockedKeyboardState: KeyboardState?)
}

@objc(KBGKeyboardGuide)
public final class KeyboardGuide: NSObject {
    private let isShared: Bool

    @objc(sharedGuide)
    public static let shared = KeyboardGuide(shared: true)

    public convenience override init() {
        self.init(shared: false)
    }

    private init(shared: Bool) {
        isShared = shared

        super.init()
    }

    deinit {
        if isShared {
            NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc
    public private(set) var isActive: Bool = false

    @objc
    public func activate() {
        assert(Thread.isMainThread, "Must be called on main thread")

        guard !isActive else { return }
        isActive = true

        if isShared {
            NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    // MARK: - Observer

    private let didChangeStateNotification = Notification.Name("KBGKeyboardGuideDidChangeStateNotification")

    @objc
    private final class ObserverNotificationProxy: NSObject {
        weak var observer: KeyboardGuideObserver?

        init(observer: KeyboardGuideObserver) {
            self.observer = observer
        }

        @objc
        func keyboardGuideDidChangeState(_ notification: Notification) {
            guard let keyboardGuide = notification.object as? KeyboardGuide else { return }
            observer?.keyboardGuide(keyboardGuide, didChangeDockedKeyboardState: keyboardGuide.dockedKeyboardState)
        }
    }

    private static var notificationProxyAssociationKey: UInt8 = 0

    @objc
    public func addObserver(_ observer: KeyboardGuideObserver) {
        let notificationProxy = ObserverNotificationProxy(observer: observer)
        NotificationCenter.default.addObserver(notificationProxy, selector: #selector(ObserverNotificationProxy.keyboardGuideDidChangeState(_:)), name: didChangeStateNotification, object: self)
        objc_setAssociatedObject(observer, &KeyboardGuide.notificationProxyAssociationKey, notificationProxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc
    public func removeObserver(_ observer: KeyboardGuideObserver) {
        objc_setAssociatedObject(observer, &KeyboardGuide.notificationProxyAssociationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - Properties

    @objc
    public var dockedKeyboardState: KeyboardState? {
        didSet {
            let notification = Notification(name: didChangeStateNotification, object: self, userInfo: nil)
            NotificationCenter.default.post(notification)
        }
    }

    // MARK: - Notifications

    /**
     When the application entered in background, iOS may send multiple state change events to the application,
     such as trait collection change events to capture screen image in both orientations for the application switcher.

     In some cases, the application may change its view structure and the text fields may resign first responder.
     However, since the application has entered in background, iOS will _NOT_ send any keyboard notifications to the application.

     Therefore, logically, there are no ways to know the current keyboard state after the application is entering background.
     To workaround this behavior, it retains the current first responder and restore it if `shouldRestoreFirstResponder` returns `true`
     (Default to `true` if it is `UITextInputTraits` such as `UITextView`.)

     - SeeAlso:
     `UIResponder.shouldRestoreFirstResponder`
    */
    private var lastFirstResponder: UIResponder?

    @objc
    public func applicationDidEnterBackground(_ notification: Notification) {
        guard isShared else { return }

        lastFirstResponder = UIResponder.currentFirstResponder
    }

    @objc
    public func applicationWillEnterForeground(_ notification: Notification) {
        guard isShared else { return }

        guard let lastFirstResponder = lastFirstResponder else { return }
        self.lastFirstResponder = nil

        // Try to restore the first responder to maintain the last keyboard state.
        if lastFirstResponder.shouldRestoreFirstResponder, lastFirstResponder.becomeFirstResponder() {
            return
        }

        // In case it doesn't or can't restore the first responder,
        // assume that there are no keyboard remaining on the screen.
        dockedKeyboardState = nil
    }

    @objc
    public func keyboardWillShow(_ notification: Notification) {
        // _MAY BE_ called in `UIView` animation block.
        updateKeyboardState(with: notification)
    }

    @objc
    public func keyboardWillHide(_ notification: Notification) {
        // _MAY BE_ called in `UIView` animation block.
        dockedKeyboardState = nil
    }

    @objc
    public func keyboardWillChangeFrame(_ notification: Notification) {
        // _MAY BE_ called in `UIView` animation block.

        // Only update docked keyboard state when the keyboard is currently docked.
        guard dockedKeyboardState != nil else { return }

        updateKeyboardState(with: notification)
    }

    private func updateKeyboardState(with notification: Notification) {
        guard let isLocal = notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            return
        }

        // `UIResponder.keyboardWillChangeFrameNotification` _MAY BE_ posted with `CGRect.zero` frame.
        // Ignore it, which is useless.
        if frame == CGRect.zero {
            return
        }

        let coordinateSpace: UICoordinateSpace
        let keyboardContainerBounds: CGRect
        let keyboardFrame: CGRect
        if #available(iOS 16.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            // iPadOS 16.0 and later supports Stage Manager that introduced multiple edge cases.
            // Note that iPadOS 16.0 was not released and first release version is iPadOS 16.1.

            // On iPadOS 16.0 and later, the keyboard frame is on the screen coordinate.
            let keyboardScreen = UIScreen.main
            coordinateSpace = keyboardScreen.coordinateSpace

            // `keyWindow` is deprecated API, however, it gives the right current key window.
            if let keyWindow = UIApplication.shared.keyWindow {
                // Do not use `window.frame`, which is not in the screen coordinate space.
                let keyWindowFrame = coordinateSpace.convert(keyWindow.bounds, from: keyWindow)

                // On iPad 16.0 and later, sometimes the keyboard frame is clipped in the key window frame.
                // This is an arbitrary condition if it's clipped.
                if frame.width == keyWindowFrame.width {
                    keyboardContainerBounds = keyWindowFrame
                    keyboardFrame = frame
                } else {
                    keyboardContainerBounds = keyboardScreen.bounds

                    // In case the keyboard frame is not clipped, sometimes the keyboard frame is positioned
                    // wrongly such as off the screen, or wrongly using key window frame origin X.
                    // Use keyboard container origin X instead, since keyboard is always appearing
                    // in full-width.
                    keyboardFrame = CGRect(x: keyboardContainerBounds.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height)
                }
            } else {
                // In case we can't find key window, which is unlikely happening.
                keyboardContainerBounds = keyboardScreen.bounds
                keyboardFrame = frame
            }
        } else if #available(iOS 13.0, *) {
            // On iOS 13.0 and later, the keyboard frame is on the screen coordinate.
            let keyboardScreen = UIScreen.main
            coordinateSpace = keyboardScreen.coordinateSpace
            // The keyboard container is always screen bounds, can be larger than window frame.
            keyboardContainerBounds = keyboardScreen.bounds
            keyboardFrame = frame
        } else if let keyWindow = UIApplication.shared.keyWindow {
            // On prior to iOS 13.0, the keyboard frame is on the window coordinate.
            let keyboardScreen = keyWindow.screen
            coordinateSpace = keyWindow
            // The keyboard container is always screen bounds, can be larger than window frame.
            keyboardContainerBounds = coordinateSpace.convert(keyboardScreen.bounds, from: keyboardScreen.coordinateSpace)
            keyboardFrame = CGRect(x: keyboardContainerBounds.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height)
        } else {
            return
        }

        // While the main screen bound is being changed, notifications _MAY BE_ posted with wrong frame.
        // Ignore it, because it will be eventual consistent with the following notifications.
        if keyboardContainerBounds.width != keyboardFrame.width {
            return
        }

        dockedKeyboardState = KeyboardState(isLocal: isLocal, frame: keyboardFrame, coordinateSpace: coordinateSpace)
    }
}
