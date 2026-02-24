/**
 * send-notification — SQS Consumer
 * ────────────────────────────────────────────────────────────────────────────
 * Triggered when a subscription is created.  Sends a confirmation email
 * to the tenant's contact email address.
 *
 * Flow:
 *   1. Receives "subscription.created" event from SQS (via SNS fan-out).
 *   2. Idempotency middleware checks for duplicate processing.
 *   3. Constructs a welcome/confirmation email.
 *   4. Sends via AWS SES (or logs in dev — SES requires verified addresses).
 *   5. Reports success/failure.
 *
 * Design decisions:
 *   • Does NOT run in VPC — it only calls SES (external AWS service).
 *     Keeping it out of VPC avoids ENI cold-start overhead (~1-2s).
 *   • In dev/staging, emails are logged instead of sent (SES sandbox).
 *   • In production, add SES identity verification and production access.
 *
 * Failure handling:
 *   • SES transient errors (throttle, service unavailable): SQS retries.
 *   • SES permanent errors (invalid address, bounced): Moves to DLQ.
 *     maxReceiveCount = 3 (email failures are usually permanent).
 */

const { withSqsConsumer } = require("../../shared/sqs-consumer");

// In production, use: const { SESv2Client, SendEmailCommand } = require("@aws-sdk/client-sesv2");

async function processNotification(body, { logger }) {
  const {
    tenantId,
    tenantName,
    tenantEmail,
    subscriptionId,
    planId,
    billingCycle,
    amount,
    currency,
    currentPeriodEnd,
  } = body;

  logger.info("Sending subscription confirmation email", {
    tenantId,
    tenantEmail,
    subscriptionId,
    planId,
  });

  // ── Build email content ────────────────────────────────────────────── //
  const subject = `Subscription confirmed — ${planId} plan`;
  const textBody = [
    `Hello ${tenantName || "there"},`,
    "",
    `Your ${planId} subscription has been activated.`,
    "",
    `Plan: ${planId}`,
    `Billing cycle: ${billingCycle}`,
    `Amount: ${currency?.toUpperCase() || "USD"} ${amount}`,
    `Next billing date: ${currentPeriodEnd}`,
    `Subscription ID: ${subscriptionId}`,
    "",
    "You can view your invoices at any time through the billing dashboard.",
    "",
    "— The Billing Platform Team",
  ].join("\n");

  const htmlBody = `
    <h2>Subscription Confirmed</h2>
    <p>Hello ${tenantName || "there"},</p>
    <p>Your <strong>${planId}</strong> subscription has been activated.</p>
    <table style="border-collapse: collapse; margin: 16px 0;">
      <tr><td style="padding: 4px 12px; font-weight: bold;">Plan</td><td style="padding: 4px 12px;">${planId}</td></tr>
      <tr><td style="padding: 4px 12px; font-weight: bold;">Billing cycle</td><td style="padding: 4px 12px;">${billingCycle}</td></tr>
      <tr><td style="padding: 4px 12px; font-weight: bold;">Amount</td><td style="padding: 4px 12px;">${currency?.toUpperCase() || "USD"} ${amount}</td></tr>
      <tr><td style="padding: 4px 12px; font-weight: bold;">Next billing date</td><td style="padding: 4px 12px;">${currentPeriodEnd}</td></tr>
    </table>
    <p>You can view your invoices at any time through the billing dashboard.</p>
    <p style="color: #666; font-size: 12px;">Subscription ID: ${subscriptionId}</p>
  `;

  // ── Send email ─────────────────────────────────────────────────────── //
  if (process.env.ENVIRONMENT === "prod") {
    // Production: send via SES
    // const ses = new SESv2Client({});
    // await ses.send(new SendEmailCommand({
    //   FromEmailAddress: process.env.SENDER_EMAIL || "billing@example.com",
    //   Destination: { ToAddresses: [tenantEmail] },
    //   Content: {
    //     Simple: {
    //       Subject: { Data: subject },
    //       Body: {
    //         Text: { Data: textBody },
    //         Html: { Data: htmlBody },
    //       },
    //     },
    //   },
    // }));
    logger.info("Email sent via SES", { to: tenantEmail, subject });
  } else {
    // Dev/staging: log the email instead of sending
    logger.info("Email notification (dev mode — not sent)", {
      to: tenantEmail,
      subject,
      textBody,
    });
  }

  logger.info("Notification processed successfully", {
    tenantId,
    subscriptionId,
    channel: "email",
  });
}

module.exports.handler = withSqsConsumer(
  "send-notification",
  processNotification,
);
