/**
 * Business error raised by the wizard services. Controllers translate it into an AuraHandledException
 * so the message reaches the user as written.
 */
public with sharing class WizardException extends Exception {
}
