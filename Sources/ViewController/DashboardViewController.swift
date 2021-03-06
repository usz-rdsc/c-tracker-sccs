//
//  DashboardViewController.swift
//  c3-pro
//
//  Created by Pascal Pfiffner on 7/31/15.
//  Copyright (c) 2015 Boston Children's Hospital. All rights reserved.
//

import UIKit
import SMART
import C3PRO
import ResearchKit

let kDashboardTodayActivityNumDays = 2
let kDashboardActivityNumDays = 7


class DashboardViewController: UITableViewController {
	
	deinit {
		NotificationCenter.default.removeObserver(self)
	}
	
	var willReloadTable = false
	
	var showSpinnerInCell: IndexPath?
	
	var server: Server?
	
	var profileManager: ProfileManager?
	
	var taskPreparer: UserTaskPreparer?
	
	var user: User? {
		return profileManager?.user
	}
	
	/// will only include one task per task.id!
	var tasksOutstanding: [UserTask] {
		var found = Set<String>()
		let outstanding = user?.tasksOutstanding.filter() {
			if found.contains($0.taskId) {
				return false
			}
			found.insert($0.taskId)
			return true
		}
		return outstanding ?? []
	}
	
	var tasksDone: [UserTask] {
		return user?.tasksPast ?? []
	}
	
	var questionnaireController: QuestionnaireController?
	
	
	// MARK: - View Tasks
	
	override func awakeFromNib() {
		registerForNotifications()
	}
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		// image as title view
		let img = UIImage(named: "dashboard")
		let imgview = UIImageView(image: img)
		navigationItem.titleView = imgview
	}
	
	override func viewWillAppear(_ animated: Bool) {
		updateTasks()
		if nil == healthReport || nil == recentHealthReport {
			refreshHealthData()
		}
		if nil == motionReport || nil == todayReport {
			refreshMotionData()
		}
	}
	
	
	// MARK: - Actions
	
	func updateTasks() {
		if !willReloadTable {
			willReloadTable = true
			DispatchQueue.main.async {
				self.willReloadTable = false
				self.tableView.reloadData()
			}
		}
	}
	
	func showTask(_ task: UserTask, indexPath: IndexPath, animated: Bool = true) {
		if .consent == task.type {
			showConsent(animated)
		}
		else if .survey == task.type {
			showSpinnerAt(indexPath)
			startSurveyTask(task, animated: animated) { error in
				self.showSpinnerAt(indexPath, show: false)
				if let error = error {
					self.show(error: error, title: "Cannot Start Task".sccs_loc)
				}
			}
		}
	}
	
	func taskAtIndexPath(_ indexPath: IndexPath) -> UserTask? {
		let tasks = 0 == indexPath.section ? tasksOutstanding : tasksDone
		if tasks.count > indexPath.row {
			return tasks[indexPath.row]
		}
		return nil
	}
	
	func userDidSomething(_ notification: Notification?) {
		updateTasks()
	}
	
	
	// MARK: - Questionnaires
	
	func startSurveyTask(_ task: UserTask, animated: Bool = true, started: @escaping ((Error?) -> Void)) {
		guard let user = user else {
			started(C3Error.noUserEnrolled)
			return
		}
		
		taskPreparer = taskPreparer ?? UserTaskPreparer(user: user, server: server)
		taskPreparer!.prepareResource(for: task) { resource, error in
			if let questionnaire = resource as? Questionnaire {
				
				// got a questionnaire, setup a questionnaire controller and launch!
				let quest = QuestionnaireController(questionnaire: questionnaire)
				quest.whenCompleted = { viewController, answers in
					self.didCompleteQuestionnaireTask(task, answers: answers)
				}
				quest.whenCancelledOrFailed = { viewController, error in
					self.didCancelOrFailQuestionnaireTask(task, error: error)
				}
				
				quest.prepareQuestionnaireViewController() { viewController, error in
					if let vc = viewController {
						self.present(vc, animated: animated)
						started(nil)
					}
					else {
						started(error ?? C3Error.questionnaireUnknownError)
					}
				}
				self.questionnaireController = quest
			}
			else {
				started(error ?? C3Error.questionnaireUnknownError)
			}
		}
	}
	
	func didCompleteQuestionnaireTask(_ task: UserTask, answers: QuestionnaireResponse?) {
		if let answers = answers {
			do {
				try profileManager?.userDidComplete(task: task, on: Date(), context: answers)
				dismiss(animated: true)
			}
			catch let error {
				dismiss(animated: true) {
					self.show(error: error)
				}
			}
		}
		else {
			c3_logIfDebug("Finished questionnaire but no answers received, not marking as completed")
			dismiss(animated: true)
		}
	}
	
	func didCancelOrFailQuestionnaireTask(_ task: UserTask, error: Error?) {
		dismiss(animated: true, completion: nil)
		if let error = error {
			c3_logIfDebug("Questionnaire failed: \(error)")
			self.show(error: error)
		}
	}
	
	
	// MARK: - Consent
	
	func showConsent(_ animated: Bool = true) {
		let pdfController = PDFViewController()
		if let url = ConsentController.signedConsentPDFURL(mustExist: true) ?? ConsentController.bundledConsentPDFURL() {
			if let navi = navigationController {
				pdfController.title = "Consent".sccs_loc
				pdfController.hidesBottomBarWhenPushed = true
				pdfController.startURL = url
				navi.pushViewController(pdfController, animated: true)
			}
			else {
				c3_logIfDebug("I must be embedded in a navigation controller to show the consent")
			}
		}
		else {
			c3_logIfDebug("FAILED to locate «consent.pdf»")
		}
	}
	
	
	// MARK: - Activity
	
	var refreshingHealthData = false
	
	var refreshingMotion = false
	
	lazy var healthReporter = HealthKitReporter()
	
	var motionReporter: CoreMotionReporter?
	
	var healthReport: ActivityReport? {
		didSet {
			redrawHealthReport()
		}
	}
	
	var localizedStringForStepCount: String?
	
	var recentHealthReport: ActivityReport? {
		didSet {
			localizedStringForStepCount = nil
			if let report = recentHealthReport {
				let formatter = NumberFormatter()
				formatter.numberStyle = .decimal
				formatter.maximumFractionDigits = 0
				
				var stepstr: String?
				var fligstr: String?
				if let samples = report.last?.healthKitSamples {
					for sample in samples {
						if HKQuantityTypeIdentifier.stepCount.rawValue == sample.quantityType.identifier {
							let quantity = try? sample.c3_asFHIRQuantity()
							let daily = quantity?.value?.decimal ?? Decimal(0)
							stepstr = formatter.string(from: NSDecimalNumber(decimal: daily)) ?? stepstr
						}
						else if HKQuantityTypeIdentifier.flightsClimbed.rawValue == sample.quantityType.identifier {
							let quantity = try? sample.c3_asFHIRQuantity()
							let daily = quantity?.value?.decimal ?? Decimal(0)
							fligstr = formatter.string(from: NSDecimalNumber(decimal: daily)) ?? fligstr
						}
					}
				}
				
				if let steps = stepstr {
					if let flights = fligstr {
						localizedStringForStepCount = "{{steps}} steps, {{flights}} floors climbed".sccs_loc.replacingOccurrences(of: "{{steps}}", with: steps).replacingOccurrences(of: "{{flights}}", with: flights)
					}
					else {
						localizedStringForStepCount = "{{steps}} steps".sccs_loc.replacingOccurrences(of: "{{steps}}", with: steps)
					}
				}
			}
			redrawRecentHealthReport()
		}
	}
	
	var todayReport: ActivityReport? {
		didSet {
			#if DEBUG
			if let today = todayReport {
				print("\(today)")
				if let activities = today.periods.first?.coreMotionActivities {
					for period in activities {
						print("-- \(period)")
					}
				}
			}
			#endif
			redrawTodayReport()
		}
	}
	
	var motionReport: ActivityReport? {
		didSet {
			redrawMotionReport()
		}
	}
	
	func refreshHealthData(isRetry: Bool = false) {
		if refreshingHealthData {
			return
		}
		refreshingHealthData = true
		c3_logIfDebug("Refreshing health data")
		
		// 1: progressive health report
		healthReporter.progressivelyCollatedActivityData() { report, error in
			self.refreshingHealthData = false
			if let error = error {
				if isRetry {
					c3_logIfDebug("Cannot refresh health data: tried to get permission from HealthKit, not received")
					self.show(error: error)
				}
				else if let m = self.profileManager {
					m.permissioner.requestPermission(for: .healthKit(m.healthKitTypes)) { error in
						if let error = error {
							self.show(error: error)
						}
						else {
							self.refreshHealthData(isRetry: true)
						}
					}
				}
				return
			}
			else {
				self.healthReport = report
				c3_logIfDebug("Health data refreshed (progressive)")
			}
			
			/*/ 2: recent steps
			let start = Date(timeIntervalSinceNow: Double(kDashboardTodayActivityNumDays * 24 * -3600))
			self.refreshingHealthData = true
			self.healthReporter.reportForActivityPeriod(startingAt: start, until: Date()) { period, error in
				self.refreshingHealthData = false
				if let error = error {
					c3_logIfDebug("Cannot refresh recent health data: \(error)")
				}
				else {
					self.recentHealthReport = (nil == period) ? nil : ActivityReport(periods: [period!])
					c3_logIfDebug("Health data refreshed (recent)")
				}
			}	*/
		}
	}
	
	func refreshMotionData(isRetry: Bool = false) {
		guard let motionReporter = motionReporter else {
			c3_logIfDebug("Error: \(self) does not have `motionReporter` set, cannot refresh motion data")
			return
		}
		if refreshingMotion {
			return
		}
		if let m = profileManager, !m.permissioner.hasPermission(for: .coreMotion), !isRetry {
			m.permissioner.requestPermission(for: .coreMotion) { error in
				if let error = error {
					self.show(error: error)
				}
				else {
					self.refreshMotionData(isRetry: true)
				}
			}
			return
		}
		
		refreshingMotion = true
		c3_logIfDebug("Refreshing motion data")
		
		// 1: today report
		let now = Date()
		let today = Date(timeIntervalSinceNow: Double(kDashboardTodayActivityNumDays * 24 * -3600))
		
		motionReporter.reportForActivityPeriod(startingAt: today, until: now) { period, error in
			self.refreshingMotion = false
			if let period = period {
				self.todayReport = ActivityReport(periods: [period])
				c3_logIfDebug("Today data refreshed")
			}
			else {
				c3_logIfDebug("No today data")
			}
			
			/*/ 2: progressive history
			self.refreshingMotion = true
			motionReporter.progressivelyCollatedActivityData() { report, error in
				self.refreshingMotion = false
				self.motionReport = report
				c3_logIfDebug("Motion data refreshed")
			}	*/
		}
	}
	
	func redrawTodayReport() {
		tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
	}
	
	func redrawRecentHealthReport() {
		tableView.reloadRows(at: [], with: .none)
	}
	
	func redrawMotionReport() {
		tableView.reloadRows(at: [], with: .none)
	}
	
	func redrawHealthReport() {
		tableView.reloadRows(at: [IndexPath(row: 1, section: 1), IndexPath(row: 2, section: 1)], with: .none)
	}
	
	
	// MARK: - Graphing Data Sources
	
	var pieSource: PieDataSource?
	
	var stepGraphSource: HealthGraphDataSource?
	
	var flightGraphSource: HealthGraphDataSource?
	
	
	// MARK: - Table View Data Source
	
	override func numberOfSections(in tableView: UITableView) -> Int {
		return 3
	}
	
	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		if 0 == section {
			return max(tasksOutstanding.count, 1)
		}
		if 1 == section {
			return 3
		}
		return tasksDone.count
	}
	
	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		if 0 == section {
			if 0 == tasksOutstanding.count {
				return nil
			}
			let ttl = "Your Tasks".sccs_loc
			return (tasksOutstanding.filter() { $0.due }.count > 0) ? "🔔 \(ttl)" : ttl
		}
		if 1 == section {
			return "Recent Activity".sccs_loc
		}
		if tasksDone.count > 0 {
			return "Completed Tasks".sccs_loc
		}
		return nil
	}
	
	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		if 1 == indexPath.section {
			if 0 == indexPath.row {
				let cell = tableView.dequeueReusableCell(withIdentifier: "C3ActivityCell", for: indexPath) as! DashboardActivityTableViewCell
				pieSource = PieDataSource(report: todayReport)
				cell.setup(with: pieSource!)
				cell.legendTitle?.text = "Past {{days}} Days".sccs_loc.replacingOccurrences(of: "{{days}}", with: "\(kDashboardTodayActivityNumDays)")
				return cell
			}
			
			// graphs
			if 1 == indexPath.row {
				let cell = tableView.dequeueReusableCell(withIdentifier: "C3GraphCell", for: indexPath) as! DashboardGraphTableViewCell
				stepGraphSource = HealthGraphDataSource(report: healthReport)
				stepGraphSource?.wantedPlotIndex = 0
				cell.graph?.dataSource = stepGraphSource
				cell.graph?.noDataText = "No step data".sccs_loc
				cell.label?.text = "Steps taken per day".sccs_loc
				return cell
			}
			if 2 == indexPath.row {
				let cell = tableView.dequeueReusableCell(withIdentifier: "C3GraphCell", for: indexPath) as! DashboardGraphTableViewCell
				flightGraphSource = HealthGraphDataSource(report: healthReport)
				flightGraphSource?.wantedPlotIndex = 1
				cell.graph?.dataSource = flightGraphSource
				cell.graph?.noDataText = "No stair data".sccs_loc
				cell.label?.text = "Flights climbed per day".sccs_loc
				return cell
			}
			
			// steps and flights - DISABLED FOR NOW
			let cell = tableView.dequeueReusableCell(withIdentifier: "C3TextCell", for: indexPath) 
			if let stepstr = localizedStringForStepCount {
				cell.textLabel?.textColor = UIColor.black
				cell.textLabel?.text = stepstr
			}
			else {
				cell.textLabel?.textColor = UIColor.lightGray
				cell.textLabel?.text = refreshingHealthData ? "Refreshing activity data...".sccs_loc : "Step count not available".sccs_loc
			}
			return cell
		}
		
		// tasks due and completed
		let cell = tableView.dequeueReusableCell(withIdentifier: "C3TaskCell", for: indexPath) as! DashboardTaskTableViewCell
		if let task = taskAtIndexPath(indexPath) {
			cell.labelTask?.text = task.title ?? task.type.localizedName
			cell.progress?.image = progressImage(for: task)
			cell.accessoryType = task.canReview ? .disclosureIndicator : .none
			
			if task.due {
				cell.labelDate?.textColor = UIColor(red:1, green:0.68, blue:0, alpha:1)
				cell.labelDate?.text = "due".sccs_loc
			}
			else if task.completed || task.expired {
				cell.labelDate?.textColor = task.expired ? UIColor.red : UIColor.lightGray
				cell.labelDate?.text = task.humanCompletedExpiredDate
			}
			else {
				cell.labelDate?.textColor = UIColor.darkGray
				cell.labelDate?.text = task.humanDueDate
			}
		}
		
		// no task at this row - should only happen if there are no more tasks
		else {
			cell.labelTask?.text = "All your tasks are done".sccs_loc
			cell.progress?.image = UIImage(named: "progress_done")
			cell.labelDate?.text = nil
		}
		
		// do we want a spinner?
		if let ip = showSpinnerInCell, ip == indexPath {
			let activity = UIActivityIndicatorView(activityIndicatorStyle: .gray)
			cell.accessoryView = activity
			cell.labelDate?.text = nil
			activity.startAnimating()
		}
		return cell
	}
	
	
	// MARK: - Table View Delegate
	
	override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
		if 1 == indexPath.section {
			if 0 == indexPath.row {
				return min(200.0, max(150.0, tableView.bounds.size.width / 2.5))
			}
			if indexPath.row > 0 {
				return min(160.0, max(120.0, tableView.bounds.size.width / 3.1))
			}
			return UITableViewAutomaticDimension
		}
		return 76.0
	}
	
	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		if 1 == indexPath.section {
			if 0 == indexPath.row {
				refreshMotionData()
			}
			else {
				refreshHealthData()
			}
			tableView.deselectRow(at: indexPath, animated: true)
		}
		else {
			if let task = taskAtIndexPath(indexPath) {
				if task.due || task.canReview {
					showTask(task, indexPath: indexPath, animated: true)
				}
				else {
					let formatter = DateFormatter()
					formatter.dateStyle = .long
					formatter.timeStyle = .none
					if task.pending {
						let title = "{{title}} is not yet due".sccs_loc.replacingOccurrences(of: "{{title}}", with: task.title ?? task.type.localizedName)
						let msg = "There's still some time until {{due_date}}".sccs_loc.replacingOccurrences(of: "{{due_date}}", with: formatter.string(from: task.dueDate!))
						show(message: msg, title: title)
					}
					else if task.expired {
						let title = "{{title}} has expired".sccs_loc.replacingOccurrences(of: "{{title}}", with: task.title ?? task.type.localizedName)
						let msg = "It has expired {{expiry_date}}".sccs_loc.replacingOccurrences(of: "{{expiry_date}}", with: formatter.string(from: task.expiredDate!))
						show(message: msg, title: title)
					}
				}
			}
			tableView.deselectRow(at: indexPath, animated: true)
		}
	}
	
	func dismissPresentedViewController() {
		dismiss(animated: true, completion: nil)
	}
	
	
	// MARK: - Notifications
	
	func registerForNotifications() {
		let center = NotificationCenter.default
		center.addObserver(self, selector: #selector(DashboardViewController.userDidSomething(_:)), name: UserDidReceiveTaskNotification, object: nil)
		center.addObserver(self, selector: #selector(DashboardViewController.userDidSomething(_:)), name: UserDidCompleteTaskNotification, object: nil)
	}
	
	
	// MARK: - Utilities
	
	func progressImage(for task: UserTask) -> UIImage? {
		if task.completed {
			return UIImage(named: "progress_done")
		}
		if task.due {
			return UIImage(named: "progress_due")
		}
		return UIImage(named: "progress_pending")
	}
	
	func showSpinnerAt(_ indexPath: IndexPath, show: Bool = true) {
		showSpinnerInCell = show ? indexPath : nil
		tableView.reloadRows(at: [indexPath], with: .none)
	}
}


class DashboardTaskTableViewCell : UITableViewCell {
	
	@IBOutlet var labelTask: UILabel?
	
	@IBOutlet var labelDate: UILabel?
	
	@IBOutlet var progress: UIImageView?
}


class DashboardActivityTableViewCell: UITableViewCell {
	
	@IBOutlet var pie: ORKPieChartView?
	
	@IBOutlet var legendTitle: UILabel?
	
	
	func setup(with dataSource: PieDataSource) {
		guard let supr = legendTitle?.superview else {
			c3_logIfDebug("Legend title view does not have a superview, cannot set up")
			return
		}
		guard let activities = dataSource.nonZeroActivities else {
			c3_logIfDebug("Not a single activity in \(dataSource), will not try to create a legend")
			return
		}
		
		pie?.dataSource = dataSource
		pie?.lineWidth = 12.0
		
		// clean legend area and add legend items
		supr.subviews.filter() { $0 != legendTitle }.forEach() { $0.removeFromSuperview() }
		for activity in activities {
			let view = row(for: activity)
			let prev = supr.subviews.last!
			supr.addSubview(view)
			supr.addConstraint(NSLayoutConstraint(item: view, attribute: .leading, relatedBy: .equal, toItem: supr, attribute: .leading, multiplier: 1.0, constant: 0.0))
			supr.addConstraint(NSLayoutConstraint(item: view, attribute: .trailing, relatedBy: .equal, toItem: supr, attribute: .trailing, multiplier: 1.0, constant: 0.0))
			supr.addConstraint(NSLayoutConstraint(item: view, attribute: .top, relatedBy: .equal, toItem: prev, attribute: .bottom, multiplier: 1.0, constant: 4.0))
		}
	}
	
	func row(for activity: CoreMotionActivitySum) -> UIView {
		let view = UIView()
		view.translatesAutoresizingMaskIntoConstraints = false
		
		let blob = UIView()
		blob.translatesAutoresizingMaskIntoConstraints = false
		blob.backgroundColor = activity.preferredColorWithSaturation(0.7, brightness: 0.94)
		blob.layer.cornerRadius = 6.0
		view.addSubview(blob)
		view.addConstraint(NSLayoutConstraint(item: blob, attribute: .leading, relatedBy: .equal, toItem: view, attribute: .leading, multiplier: 1.0, constant: 0.0))
		blob.addConstraint(NSLayoutConstraint(item: blob, attribute: .width, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 0.0, constant: 12.0))
		blob.addConstraint(NSLayoutConstraint(item: blob, attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 0.0, constant: 12.0))
		
		let label = UILabel()
		label.translatesAutoresizingMaskIntoConstraints = false
		label.text = activity.type.humanName
		label.font = UIFont.preferredFont(forTextStyle: .footnote)
		label.textColor = UIColor.gray
		view.addSubview(label)
		view.addConstraint(NSLayoutConstraint(item: label, attribute: .leading, relatedBy: .equal, toItem: blob, attribute: .trailing, multiplier: 1.0, constant: 8.0))
		view.addConstraint(NSLayoutConstraint(item: label, attribute: .trailing, relatedBy: .equal, toItem: view, attribute: .trailing, multiplier: 1.0, constant: 0.0))
		view.addConstraint(NSLayoutConstraint(item: label, attribute: .top, relatedBy: .equal, toItem: view, attribute: .top, multiplier: 1.0, constant: 3.0))
		view.addConstraint(NSLayoutConstraint(item: label, attribute: .bottom, relatedBy: .equal, toItem: view, attribute: .bottom, multiplier: 1.0, constant: 3.0))
		view.addConstraint(NSLayoutConstraint(item: blob, attribute: .centerY, relatedBy: .equal, toItem: label, attribute: .centerY, multiplier: 1.0, constant: 0.0))
		
		return view
	}
}

class DashboardGraphTableViewCell: UITableViewCell {
	
	@IBOutlet var graph: ORKGraphChartView?
	
	@IBOutlet var label: UILabel?
}


extension CoreMotionActivitySum {
	
	public func preferredColorWithSaturation(_ saturation: CGFloat, brightness: CGFloat) -> UIColor {
		let (hue, sat, bright) = preferredColorComponentsHSB()
		return UIColor(hue: CGFloat(hue), saturation: CGFloat(sat), brightness: CGFloat(bright), alpha: 1.0)
	}
}

