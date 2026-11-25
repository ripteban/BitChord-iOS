import UIKit

/// The bottom of the app, drawn natively the way Apple Music draws it on iOS 26:
/// a floating Liquid Glass capsule of tabs, and the mini player in its own
/// capsule above it. The page (web/app/src/shell/NativeChrome.tsx) reports what's
/// playing and where the user is; taps go back to it as actions.
@MainActor
final class NativeChromeView: UIView {
    struct Tab {
        let title: String
        let symbol: String
        let path: String
        let matches: (String) -> Bool
    }

    static let tabs: [Tab] = [
        Tab(title: "Inicio", symbol: "house.fill", path: "/home", matches: { $0 == "/" || $0.hasPrefix("/home") }),
        Tab(title: "Novedades", symbol: "square.grid.2x2.fill", path: "/new", matches: { $0.hasPrefix("/new") }),
        Tab(title: "Biblioteca", symbol: "music.note.list", path: "/library/playlists", matches: { $0.hasPrefix("/library") }),
        Tab(title: "Buscar", symbol: "magnifyingglass", path: "/search", matches: { $0.hasPrefix("/search") }),
    ]

    static let accent = UIColor(red: 0.98, green: 0.18, blue: 0.29, alpha: 1)
    static let tabBarHeight: CGFloat = 62
    static let miniHeight: CGFloat = 56

    /// Called with ("navigate", path), ("togglePlay", nil), ("next", nil), ("openPlayer", nil),
    /// ("menu", nil) and ("diagnostics", nil).
    var onAction: ((String, String?) -> Void)?

    private let tabBar = GlassCapsule()
    private let menuCapsule = GlassCapsule()
    private let titleCapsule = GlassCapsule()
    private let mini = GlassCapsule()
    private let selection = UIView()
    private var tabButtons: [UIControl] = []
    private var selectedIndex: Int?

    private let artwork = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let openButton = UIButton(type: .custom)
    private var artworkURL: String?
    private static let artworkCache = NSCache<NSString, UIImage>()

    private var isCovered = false
    private var hasTrack = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        buildTopBar()
        buildTabBar()
        buildMiniPlayer()
        mini.alpha = 0
        mini.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Touches that miss the capsules go to the page underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: Top bar: the menu in a glass circle, BitChord in a glass capsule, both below the Dynamic Island

    private func buildTopBar() {
        for capsule in [menuCapsule, titleCapsule] {
            capsule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(capsule)
        }
        NSLayoutConstraint.activate([
            menuCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            menuCapsule.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),
            menuCapsule.widthAnchor.constraint(equalToConstant: 46),
            menuCapsule.heightAnchor.constraint(equalToConstant: 46),
            titleCapsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleCapsule.centerYAnchor.constraint(equalTo: menuCapsule.centerYAnchor),
            titleCapsule.heightAnchor.constraint(equalToConstant: 46),
        ])

        let menu = UIButton(type: .system)
        menu.setImage(UIImage(systemName: "line.3.horizontal", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        menu.tintColor = .label
        menu.accessibilityLabel = "Menú"
        menu.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onAction?("menu", nil)
        }, for: .touchUpInside)
        menu.translatesAutoresizingMaskIntoConstraints = false
        menuCapsule.content.addSubview(menu)
        NSLayoutConstraint.activate([
            menu.leadingAnchor.constraint(equalTo: menuCapsule.content.leadingAnchor),
            menu.trailingAnchor.constraint(equalTo: menuCapsule.content.trailingAnchor),
            menu.topAnchor.constraint(equalTo: menuCapsule.content.topAnchor),
            menu.bottomAnchor.constraint(equalTo: menuCapsule.content.bottomAnchor),
        ])

        let logo = UIImageView(image: UIImage(named: "LogoMark")?.withRenderingMode(.alwaysTemplate))
        logo.tintColor = .label
        logo.contentMode = .scaleAspectFit
        let name = UILabel()
        name.text = "BitChord"
        name.font = .systemFont(ofSize: 17, weight: .bold)
        name.textColor = .label
        let row = UIStackView(arrangedSubviews: [logo, name])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        let title = UIButton(type: .custom)
        title.accessibilityLabel = "BitChord, Inicio"
        title.translatesAutoresizingMaskIntoConstraints = false
        title.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onAction?("navigate", "/home")
        }, for: .touchUpInside)
        // Hold it for the diagnostics sheet (also: shake the phone).
        title.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(heldTitle(_:))))
        titleCapsule.content.addSubview(title)
        titleCapsule.content.addSubview(row)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 26),
            logo.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: titleCapsule.content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: titleCapsule.content.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: titleCapsule.content.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: titleCapsule.content.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: titleCapsule.content.trailingAnchor),
            title.topAnchor.constraint(equalTo: titleCapsule.content.topAnchor),
            title.bottomAnchor.constraint(equalTo: titleCapsule.content.bottomAnchor),
        ])
    }

    @objc private func heldTitle(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onAction?("diagnostics", nil)
    }

    // MARK: Tab bar

    private func buildTabBar() {
        addSubview(tabBar)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            tabBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: 2),
            tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),
        ])

        selection.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        selection.layer.cornerCurve = .continuous
        selection.isUserInteractionEnabled = false
        selection.alpha = 0
        tabBar.content.addSubview(selection)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: tabBar.content.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: tabBar.content.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: tabBar.content.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: tabBar.content.bottomAnchor, constant: -4),
        ])

        for (index, tab) in Self.tabs.enumerated() {
            let button = UIControl()
            button.accessibilityLabel = tab.title
            button.accessibilityTraits = .button
            button.isAccessibilityElement = true
            let icon = UIImageView(image: UIImage(systemName: tab.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)))
            icon.contentMode = .scaleAspectFit
            icon.tintColor = .label
            let label = UILabel()
            label.text = tab.title
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .label
            label.textAlignment = .center
            let column = UIStackView(arrangedSubviews: [icon, label])
            column.axis = .vertical
            column.alignment = .center
            column.spacing = 3
            column.isUserInteractionEnabled = false
            column.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(column)
            NSLayoutConstraint.activate([
                column.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                column.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                icon.heightAnchor.constraint(equalToConstant: 24),
            ])
            button.addAction(UIAction { [weak self] _ in self?.tapTab(index) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            tabButtons.append(button)
        }
    }

    private func tapTab(_ index: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        select(index, animated: true)
        onAction?("navigate", Self.tabs[index].path)
    }

    private func select(_ index: Int?, animated: Bool) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        for (i, button) in tabButtons.enumerated() {
            let color = i == index ? Self.accent : UIColor.label
            for case let stack as UIStackView in button.subviews {
                for view in stack.arrangedSubviews {
                    (view as? UIImageView)?.tintColor = color
                    (view as? UILabel)?.textColor = color
                }
            }
            if i == index { button.accessibilityTraits.insert(.selected) } else { button.accessibilityTraits.remove(.selected) }
        }
        let move = {
            self.layoutSelection()
            self.selection.alpha = index == nil ? 0 : 1
        }
        if animated {
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState], animations: move)
        } else {
            move()
        }
    }

    private func layoutSelection() {
        guard let index = selectedIndex, index < tabButtons.count else { return }
        let button = tabButtons[index]
        let frame = button.convert(button.bounds, to: tabBar.content).insetBy(dx: 2, dy: 0)
        selection.frame = frame
        selection.layer.cornerRadius = frame.height / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSelection()
    }

    // MARK: Mini player

    private func buildMiniPlayer() {
        addSubview(mini)
        mini.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mini.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            mini.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            mini.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -8),
            mini.heightAnchor.constraint(equalToConstant: Self.miniHeight),
        ])

        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 8
        artwork.layer.cornerCurve = .continuous
        artwork.backgroundColor = .tertiarySystemFill

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        artistLabel.font = .systemFont(ofSize: 13, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        let texts = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        texts.axis = .vertical
        texts.spacing = 1
        texts.isUserInteractionEnabled = false

        let symbol = UIImage.SymbolConfiguration(pointSize: 21, weight: .bold)
        playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: symbol), for: .normal)
        playButton.tintColor = .label
        playButton.accessibilityLabel = "Play"
        playButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onAction?("togglePlay", nil)
        }, for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: symbol), for: .normal)
        nextButton.tintColor = .label
        nextButton.accessibilityLabel = "Next"
        nextButton.addAction(UIAction { [weak self] _ in self?.onAction?("next", nil) }, for: .touchUpInside)

        // The artwork and titles: one big target that opens the full player.
        openButton.accessibilityIdentifier = "miniPlayer"
        openButton.addAction(UIAction { [weak self] _ in self?.onAction?("openPlayer", nil) }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [artwork, texts, playButton, nextButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.setCustomSpacing(4, after: playButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        mini.content.addSubview(openButton)
        mini.content.addSubview(row)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: mini.content.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: mini.content.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: mini.content.centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 40),
            artwork.heightAnchor.constraint(equalToConstant: 40),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),
            openButton.leadingAnchor.constraint(equalTo: mini.content.leadingAnchor),
            openButton.topAnchor.constraint(equalTo: mini.content.topAnchor),
            openButton.bottomAnchor.constraint(equalTo: mini.content.bottomAnchor),
            openButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -4),
        ])
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        artwork.isUserInteractionEnabled = false

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedUp))
        swipe.direction = .up
        mini.addGestureRecognizer(swipe)
    }

    @objc private func swipedUp() {
        onAction?("openPlayer", nil)
    }

    // MARK: State from the page

    func apply(_ state: [String: Any]) {
        let path = state["path"] as? String ?? "/"
        select(Self.tabs.firstIndex { $0.matches(path) }, animated: true)

        let covered = (state["fullScreen"] as? Bool ?? false) || (state["drawerOpen"] as? Bool ?? false)
        if covered != isCovered {
            isCovered = covered
            isUserInteractionEnabled = !covered
            UIView.animate(withDuration: 0.25) { self.alpha = covered ? 0 : 1 }
        }

        let playing = state["playing"] as? Bool ?? false
        let symbol = UIImage.SymbolConfiguration(pointSize: 21, weight: .bold)
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: symbol), for: .normal)
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
        nextButton.isEnabled = state["hasNext"] as? Bool ?? true
        nextButton.alpha = nextButton.isEnabled ? 1 : 0.4

        let now = state["nowPlaying"] as? [String: Any]
        let track = now != nil
        if let now {
            titleLabel.text = now["title"] as? String
            let loading = state["loading"] as? Bool ?? false
            artistLabel.text = loading ? "Cargando…" : now["artist"] as? String
            openButton.accessibilityLabel = "Now playing: \(titleLabel.text ?? ""). Open the player"
            loadArtwork(now["artwork"] as? String)
        }
        if track != hasTrack {
            hasTrack = track
            if track { mini.isHidden = false }
            UIView.animate(withDuration: 0.3, animations: {
                self.mini.alpha = track ? 1 : 0
                self.mini.transform = track ? .identity : CGAffineTransform(translationX: 0, y: 12)
            }, completion: { _ in if !self.hasTrack { self.mini.isHidden = true } })
        }
    }

    private func loadArtwork(_ url: String?) {
        guard url != artworkURL else { return }
        artworkURL = url
        guard let url, let target = URL(string: url) else {
            artwork.image = nil
            return
        }
        if let cached = Self.artworkCache.object(forKey: url as NSString) {
            artwork.image = cached
            return
        }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: target), let image = UIImage(data: data) else { return }
            Self.artworkCache.setObject(image, forKey: url as NSString)
            guard let self, self.artworkURL == url else { return }
            UIView.transition(with: self.artwork, duration: 0.2, options: .transitionCrossDissolve) { self.artwork.image = image }
        }
    }
}

/// A capsule of Liquid Glass on iOS 26 (UIGlassEffect, looked up at run time so
/// the app also builds with older SDKs), frosted chrome material before that.
@MainActor
final class GlassCapsule: UIView {
    private let effectView: UIVisualEffectView
    var content: UIView { effectView.contentView }

    override init(frame: CGRect) {
        effectView = UIVisualEffectView(effect: Self.makeEffect())
        super.init(frame: frame)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.clipsToBounds = true
        effectView.layer.cornerCurve = .continuous
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if !Self.isGlass {
            // The frosted fallback gets a hairline and a soft shadow; glass brings its own.
            effectView.layer.borderWidth = 0.5
            effectView.layer.borderColor = UIColor.separator.cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 18
            layer.shadowOffset = CGSize(width: 0, height: 6)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.layer.cornerRadius = bounds.height / 2
    }

    static let isGlass: Bool = NSClassFromString("UIGlassEffect") != nil

    static func makeEffect() -> UIVisualEffect {
        if let glassClass = NSClassFromString("UIGlassEffect"),
           let glass = (glassClass as AnyObject).perform(NSSelectorFromString("new"))?.takeRetainedValue() as? UIVisualEffect
        {
            if glass.responds(to: NSSelectorFromString("setInteractive:")) {
                glass.setValue(true, forKey: "interactive")
            }
            return glass
        }
        return UIBlurEffect(style: .systemChromeMaterial)
    }
}
