//
//  LockableTabBarController.swift
//  c-tracker-sccs
//
//  Created by Pascal Pfiffner on 3/2/17.
//  Copyright (c) 2017 University Hospital Zurich. All rights reserved.
//

import UIKit
import ResearchKit

let kLastUsedTimeKey = "C3LastUsedTime"
let kAppLockTimeoutSeconds = 5.0 * 60


class LockableTabBarController: UITabBarController, ORKPasscodeDelegate {
	
	var secureView: UIView?
	
	/// Set to true the first time `viewWillAppear` is called; used to prevent view layout issues when laying out during app launch.
	var viewDidAppear = false
	
	var mustShowSecureView = false
	
	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		viewDidAppear = true
		if mustShowSecureView {
			mustShowSecureView = false
			showSecureView()
		}
	}
	
	
	// MARK: - Security & ORKPasscodeDelegate
	
	func lockApp(_ isExit: Bool = false) {
		if nil == secureView {
			UserDefaults.standard.set(Date(), forKey: kLastUsedTimeKey)
			UserDefaults.standard.synchronize()
		}
		if !isExit {
			showSecureView()
		}
	}
	
	/**
	Will first determine whether it's necessary to display the PIN screen and show it, if necessary. If it's not necessary but the screen
	is shown, will hide the lock screen.
	*/
	func unlockApp() {
		if !showPasscodeViewIfNecessary() {
			hideSecureView(false)
		}
	}
	
	/**
	If a passcode is set and the passcode view is not already showing, see if it's been longer than kAppLockTimeoutSeconds since app exit
	and, if yes, prompt for a PIN.
	*/
	func showPasscodeViewIfNecessary() -> Bool {
		if nil == secureView && ORKPasscodeViewController.isPasscodeStoredInKeychain() {
			if let lastUsedTime = UserDefaults.standard.object(forKey: kLastUsedTimeKey) as? Date {
				let timeDifference = lastUsedTime.timeIntervalSinceNow
				if timeDifference * -1 > kAppLockTimeoutSeconds {
					showPasscodeView()
					return true
				}
			}
			else {
				showPasscodeView()
				return true
			}
		}
		return false
	}
	
	func showPasscodeView(animated: Bool = true) {
		showSecureView()
		if nil != presentedViewController {
			dismiss(animated: false) {
				self.present(ORKPasscodeViewController.passcodeAuthenticationViewController(withText: nil, delegate: self), animated: animated, completion: nil)
			}
		}
		else {
			self.present(ORKPasscodeViewController.passcodeAuthenticationViewController(withText: nil, delegate: self), animated: animated, completion: nil)
		}
	}
	
	func passcodeViewControllerDidFinish(withSuccess viewController: UIViewController) {
		UserDefaults.standard.set(Date(), forKey: kLastUsedTimeKey)
		UserDefaults.standard.synchronize()
		
		hideSecureView(true)
		dismiss(animated: true, completion: nil)
	}
	
	func passcodeViewControllerDidFailAuthentication(_ viewController: UIViewController) {
	}
	
	
	// MARK: - Secure View
	
	func showSecureView() {
		if !viewDidAppear {
			mustShowSecureView = true
			return
		}
		if let viewForSnapshot = self.view, viewForSnapshot != secureView?.superview {
			if nil == secureView {
				secureView = UIView(frame: viewForSnapshot.bounds)
				secureView!.autoresizingMask = [UIViewAutoresizing.flexibleWidth, UIViewAutoresizing.flexibleHeight]
				
				let blur = UIBlurEffect(style: UIBlurEffectStyle.extraLight)
				let blurView = UIVisualEffectView(effect: blur)
				blurView.autoresizingMask = [UIViewAutoresizing.flexibleWidth, UIViewAutoresizing.flexibleHeight]
				let appIcon = UIImage(named: "ResearchInstitute")
				let appIconImageView = UIImageView(frame: CGRect(x: 0.0, y: 0.0, width: 190.0, height: 85.0))
				
				blurView.frame = secureView!.bounds
				appIconImageView.image = appIcon
				appIconImageView.center = blurView.center
				appIconImageView.contentMode = .scaleAspectFit
				
				secureView!.addSubview(blurView)
				secureView!.addSubview(appIconImageView)
				
			}
			viewForSnapshot.insertSubview(secureView!, at: .max)
			secureView!.frame = viewForSnapshot.bounds
		}
	}
	
	func hideSecureView(_ animated: Bool) {
		mustShowSecureView = false
		if let secure = secureView {
			if animated {
				let duration = 0.25
				UIView.animate(withDuration: duration) {
					secure.alpha = 0.0
				}
				
				// cannot use UIView.animateWithDuration as it will call the "completion" callback too early due to re-layout
				let after = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) + Double(Int64(duration * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
				DispatchQueue.main.asyncAfter(deadline: after) {
					secure.removeFromSuperview()
				}
			}
			else {
				secure.removeFromSuperview()
			}
			secureView = nil
		}
	}
}

