import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// ShowToastEvent reads {…} in its message as a placeholder and drops it, so "Required value {ClientName}
// is empty" would reach the rep as "Required value  is empty". Passing the text as messageData shows it as is.
export function literalToast({ title, message, variant, mode }) {
    return new ShowToastEvent({ title, message: '{0}', messageData: [message], variant, ...(mode ? { mode } : {}) });
}
