import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import Toast from 'lightning/toast';
import getFiles from '@salesforce/apex/ProjectDocsController.getFiles';
import deleteFile from '@salesforce/apex/ProjectDocsController.deleteFile';
import { fileDownloadUrl, formatBytes, reduceErrors, toTime } from 'c/projectBoardUtils';

const IMAGE_TYPES = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];

const DOCTYPE_ICONS = {
    pdf: 'doctype:pdf',
    doc: 'doctype:word',
    docx: 'doctype:word',
    xls: 'doctype:excel',
    xlsx: 'doctype:excel',
    csv: 'doctype:csv',
    ppt: 'doctype:ppt',
    pptx: 'doctype:ppt',
    txt: 'doctype:txt',
    zip: 'doctype:zip',
    xml: 'doctype:xml',
    html: 'doctype:html',
    mp4: 'doctype:video',
    mov: 'doctype:video'
};

/**
 * Salesforce Files attached to a record (issue, BRD or test case), with drag & drop upload.
 */
export default class ProjectBoardAttachments extends LightningElement {
    @api heading = 'Attachments';
    @api hint = 'Drop files here or click to upload';
    @api accept;

    files = [];
    loading = false;
    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (changed && value) {
            this.load();
        }
    }

    async load() {
        if (!this._recordId) return;
        this.loading = true;
        try {
            this.files = await getFiles({ recordId: this._recordId });
        } catch (e) {
            this.toast('Could not load attachments', reduceErrors(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    get rows() {
        return this.files.map((f) => {
            const ext = (f.extension || '').toLowerCase();
            const isImage = IMAGE_TYPES.includes(ext);
            const url = fileDownloadUrl(f.documentId);
            return {
                ...f,
                createdDate: toTime(f.createdDate),
                url,
                isImage,
                icon: isImage ? 'doctype:image' : DOCTYPE_ICONS[ext] || 'doctype:unknown',
                meta: `${formatBytes(f.size)} · ${f.createdBy}`,
                name: ext ? `${f.title}.${ext}` : f.title
            };
        });
    }

    get count() {
        return this.files.length;
    }

    get hasFiles() {
        return this.files.length > 0;
    }

    get acceptedFormats() {
        return this.accept ? this.accept.split(',') : undefined;
    }

    async handleUploadFinished(event) {
        const n = event.detail.files.length;
        this.toast(`${n} file${n === 1 ? '' : 's'} uploaded`, '', 'success');
        await this.load();
        this.dispatchEvent(new CustomEvent('change'));
    }

    async handleDelete(event) {
        const documentId = event.currentTarget.dataset.id;
        const file = this.files.find((f) => f.documentId === documentId);
        const ok = await LightningConfirm.open({
            message: `"${file.title}" will be permanently deleted.`,
            label: 'Delete file?',
            theme: 'warning'
        });
        if (!ok) return;
        try {
            await deleteFile({ documentId });
            this.files = this.files.filter((f) => f.documentId !== documentId);
            this.dispatchEvent(new CustomEvent('change'));
        } catch (e) {
            this.toast('Could not delete file', reduceErrors(e), 'error');
        }
    }

    toast(label, message, variant) {
        Toast.show({ label, message, variant, mode: 'dismissible' }, this);
    }
}
