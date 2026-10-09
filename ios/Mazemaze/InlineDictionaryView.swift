import SwiftUI
import UIKit
import MazemazeCore

/// The iPhone's own dictionary shown inside the lookup sheet. It is built for a word at most once, a moment after the sheet
/// is on screen and never during a SwiftUI layout pass (UIKit's dictionary lookup crashed on the phone when it was created
/// there). A marker file around the step lets the app switch this off by itself if it ever dies here (see CrashMarker).
struct InlineDictionaryView: UIViewControllerRepresentable {
    let term: String
    let marker: CrashMarker

    func makeUIViewController(context: Context) -> DictionaryContainerController { DictionaryContainerController(term: term, marker: marker) }
    func updateUIViewController(_ vc: DictionaryContainerController, context: Context) { vc.update(term: term) }
}

final class DictionaryContainerController: UIViewController {
    private var term: String
    private let marker: CrashMarker
    private var child: UIReferenceLibraryViewController?
    private var shownTerm: String?
    private var pending: DispatchWorkItem?

    init(term: String, marker: CrashMarker) { self.term = term; self.marker = marker; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); schedule() }

    func update(term new: String) {
        guard new != term else { return }
        term = new
        if viewIfLoaded?.window != nil { schedule() }
    }

    private func schedule() {
        pending?.cancel()
        guard shownTerm != term else { return }
        let work = DispatchWorkItem { [weak self] in self?.install() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)       // after the sheet has settled, outside any layout pass
    }

    private func install() {
        guard viewIfLoaded?.window != nil, shownTerm != term else { return }
        if let old = child { old.willMove(toParent: nil); old.view.removeFromSuperview(); old.removeFromParent(); child = nil }
        marker.begin()
        let vc = UIReferenceLibraryViewController(term: term)
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        child = vc; shownTerm = term
        let marker = marker
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { marker.end() }      // still alive: the step is done
    }

    deinit { pending?.cancel(); marker.end() }
}
