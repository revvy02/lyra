import Link from "@docusaurus/Link"
import useDocusaurusContext from "@docusaurus/useDocusaurusContext"
import Layout from "@theme/Layout"
import clsx from "clsx"
import React from "react"
import styles from "./index.module.css"

const FEATURES = [
	{
		title: "Data Safety",
		description: "Session locking prevents data corruption, atomic transactions enable safe trading, and built-in validation catches bad data before it's saved.",
	},
	{
		title: "High Performance",
		description: "Auto-sharding handles large datasets, efficient DataStore usage minimizes costs, and automatic retries handle service limits gracefully.",
	},
	{
		title: "Developer Friendly",
		description: "Schema migrations let you evolve your data format, drop-in compatibility makes switching easy, and type-safe APIs prevent common mistakes.",
	}
]

function Feature({ icon, title, description }) {
	return (
		<div className={clsx("col col--4")}>
			<div className="text--center padding-horiz--md">
				<h3>{title}</h3>
				<p>{description}</p>
			</div>
		</div>
	)
}

function HomepageFeatures() {
	return (
		<section className={styles.features}>
			<div className="container">
				<div className="row">
					{FEATURES.map((props, idx) => (
						<Feature key={idx} {...props} />
					))}
				</div>
			</div>
		</section>
	)
}

function HomepageHeader() {
	const { siteConfig } = useDocusaurusContext()

	return (
		<header className={clsx("hero", styles.heroBanner)}>
			<div className="container">
				<h1 className="hero__title">{siteConfig.title}</h1>
				<p className="hero__subtitle">
					Safe and efficient player data storage for Roblox games
				</p>
				<div className={styles.buttons}>
					<Link
						className="button button--primary button--lg"
						to="/docs/intro"
					>
						Get Started →
					</Link>
				</div>
			</div>
		</header>
	)
}

function CodeExample() {
	return (
		<div className={styles.codeExample}>
			<div className="container">
				<div className="row">
					<div className="col col--6">
						<h2>Simple Yet Powerful</h2>
						<p>
							Lyra makes it easy to handle complex data operations with a clean, intuitive API.
							From basic data storage to advanced features like atomic transactions, everything
							just works.
						</p>
					</div>
					<div className="col col--6">
						<pre className={styles.codeBlock}>
							<code>
								{`local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = {
        coins = 0,
        inventory = {},
    },
})

-- Safe updates with validation
store:update(player, function(data)
    data.coins += 100
    return true
end):expect()

-- Atomic trades between players
store:tx({player1, player2}, function(state)
    state[player1].coins -= 100
    state[player2].coins += 100
    return true
end):expect()`}
							</code>
						</pre>
					</div>
				</div>
			</div>
		</div>
	)
}

export default function Home() {
	const { siteConfig } = useDocusaurusContext()
	return (
		<Layout
			title={siteConfig.title}
			description="Safe and efficient player data storage for Roblox games"
		>
			<HomepageHeader />
			<main>
				<HomepageFeatures />
				<CodeExample />
			</main>
		</Layout>
	)
}
