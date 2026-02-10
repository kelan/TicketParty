# CommandTap tasks

set shell := ["/bin/zsh", "-cu"]

swiftformat:
    swiftformat --config config/swiftformat .

swiftlint:
    swiftlint lint --config config/swiftlint.yml

lint: swiftformat swiftlint
