import type { ReactNode } from "react";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card.tsx";

const LAST_UPDATED = "5 July 2026";
const CONTACT_EMAIL = "privacy@narica.net";

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{title}</CardTitle>
      </CardHeader>
      <CardContent className="text-muted-foreground space-y-3 text-sm leading-relaxed">
        {children}
      </CardContent>
    </Card>
  );
}

export default function Privacy() {
  return (
    <div className="mx-auto max-w-2xl px-5 py-14 sm:py-20">
      <header className="mb-10 space-y-2">
        <p className="text-muted-foreground text-sm font-medium tracking-wide uppercase">
          TriGenius
        </p>
        <h1 className="text-3xl font-semibold tracking-tight">Privacy Policy</h1>
        <p className="text-muted-foreground text-sm">
          Last updated: {LAST_UPDATED}
        </p>
      </header>

      <div className="space-y-5">
        <Section title="Overview">
          <p>
            TriGenius is an evidence-based AI triathlon coach for iPhone, iPad
            and Mac. It is designed to be private by default: your training and
            health data stay on your device and in your own private iCloud
            account. This policy explains what data TriGenius processes, where it
            is stored, and the limited cases where it is shared — always with
            your explicit consent.
          </p>
          <p>
            TriGenius is not a medical device and does not provide medical
            advice. Always consult a qualified professional before making
            training or health decisions.
          </p>
        </Section>

        <Section title="Data we process">
          <p>TriGenius works with the following categories of data:</p>
          <ul className="list-disc space-y-1.5 pl-5">
            <li>
              <strong className="text-foreground">
                Health &amp; fitness data
              </strong>{" "}
              you choose to share from Apple Health — workouts, and wellness
              signals such as heart rate, resting heart rate, heart-rate
              variability, sleep, VO₂max, FTP and body weight.
            </li>
            <li>
              <strong className="text-foreground">Garmin data</strong> — if you
              connect a Garmin account, your activities, physiological metrics
              and planned workouts, retrieved directly from Garmin on your
              behalf.
            </li>
            <li>
              <strong className="text-foreground">
                Your coaching profile
              </strong>{" "}
              — goals, event schedule, preferences and progress notes you and
              the coach build up over time.
            </li>
            <li>
              <strong className="text-foreground">Chat messages</strong> you
              exchange with the AI coach.
            </li>
          </ul>
          <p>
            TriGenius only requests the Apple Health and Calendar permissions
            needed for the features you use, and never uses this data for
            advertising, marketing or data-mining.
          </p>
        </Section>

        <Section title="Where your data is stored">
          <p>
            Your data is stored <strong className="text-foreground">on your
            device</strong> and mirrored to{" "}
            <strong className="text-foreground">your own private iCloud
            (CloudKit) database</strong> so it can follow you across your Apple
            devices. This private database is controlled by your Apple ID — we
            cannot access it. When you are not signed in to iCloud, the app runs
            as a plain local store.
          </p>
          <p>
            Your Garmin login and any AI provider key are held in the iOS/macOS
            Keychain (synchronised through iCloud Keychain), never in plain
            text.
          </p>
        </Section>

        <Section title="AI coaching &amp; third parties">
          <p>
            By default, the AI coach runs{" "}
            <strong className="text-foreground">entirely on your device</strong>{" "}
            using Apple Intelligence. In this mode your data never leaves your
            device for AI processing.
          </p>
          <p>
            You may optionally enable a cloud AI model by providing your own API
            key for{" "}
            <strong className="text-foreground">OpenRouter</strong>. This is a
            bring-your-own-key, opt-in feature. Before it is enabled, TriGenius
            shows a consent screen listing exactly what is shared. When enabled,
            the relevant parts of your workouts, health metrics, profile and
            chat messages are sent in the prompt to OpenRouter and the model
            host it routes your request to, solely to generate coaching
            responses. You can revoke this consent at any time in Settings →
            Privacy &amp; Data, which reverts the coach to the on-device model.
          </p>
          <p>The third parties TriGenius may share data with are:</p>
          <ul className="list-disc space-y-1.5 pl-5">
            <li>
              <strong className="text-foreground">Apple</strong> — iCloud
              storage of your private data (CloudKit / iCloud Keychain).
            </li>
            <li>
              <strong className="text-foreground">Garmin</strong> — only if you
              connect your Garmin account, to read your data and push planned
              workouts.
            </li>
            <li>
              <strong className="text-foreground">
                OpenRouter and the model host
              </strong>{" "}
              — only if you opt in to cloud AI with your own key.
            </li>
          </ul>
          <p>
            We do not sell your data, and we do not use any advertising or
            third-party analytics SDKs.
          </p>
        </Section>

        <Section title="Retention &amp; deleting your data">
          <p>
            Your data is kept for as long as you use the app. You are always in
            control: TriGenius includes a{" "}
            <strong className="text-foreground">“Delete all my data”</strong>{" "}
            action in Settings → Privacy &amp; Data that erases your training and
            season-plan history, coach memory, the ignored-workout list, your
            Garmin login and any AI provider key — locally and in your private
            iCloud mirror.
          </p>
          <p>
            Deleting the app also removes its on-device data; removing the
            TriGenius data from your iCloud account clears the mirrored copy.
          </p>
        </Section>

        <Section title="Your rights">
          <p>
            Depending on where you live (including under the EU/UK GDPR), you
            have the right to access, correct, export and delete your personal
            data, and to withdraw consent. Because your data lives in your own
            device and iCloud account, you can exercise most of these rights
            directly in the app. For anything else, contact us using the details
            below.
          </p>
        </Section>

        <Section title="Children">
          <p>
            TriGenius is not directed at children and is intended for use by
            adults managing their own training.
          </p>
        </Section>

        <Section title="Changes to this policy">
          <p>
            We may update this policy as the app evolves. Material changes will
            be reflected here with an updated “last updated” date.
          </p>
        </Section>

        <Section title="Contact">
          <p>
            Questions about this policy or your data? Email us at{" "}
            <a
              className="text-foreground font-medium underline underline-offset-4"
              href={`mailto:${CONTACT_EMAIL}`}
            >
              {CONTACT_EMAIL}
            </a>
            .
          </p>
        </Section>
      </div>

      <footer className="text-muted-foreground mt-12 text-center text-xs">
        © {new Date().getFullYear()} TriGenius
      </footer>
    </div>
  );
}
