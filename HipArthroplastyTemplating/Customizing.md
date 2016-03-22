# Customizing

You will be able to add your own templates to the plugin: create a directory in one of the locations loaded by the plugin, and inside that directory use the structure used in the *MEDACTA Templates* folder.


The naming convention for directories containing templates, is that their name  must end with *Templates*.


The plugin loads templates from the directories matching the naming convention in these locations:

* the plugin's Resources directory
* /Library/Application Support/OsiriX/HipArthroplastyTemplating
* ~/Library/Application Support/OsiriX/HipArthroplastyTemplating

## TXT

Inside the directory, every implant is described by a TXT file and one or two PDF files (AP and ML, meaning anterior-posterior and medial-lateral).


TXT files contain values for:

* **REF_NO**: a string
* **IMPLANT_MANUFACTURER**: a string
* **PRODUCT_FAMILY_NAME**: a string
* **SIZE**: a number
* **PRODUCT_GROUP** values: *Hip*, ... (only displayed)
* **COMPONENT_TYPE**: *Cup*, *Stem*, ...
* **FIXATION_TYPE** values: *Cemented*, *Uncemented*
* **MODULARITY_INFO** values: *Modular*, *Monobloc* (only displayed)
* **TYPE_OF_SURGERY** values: *Primary*, ... (only displayed)
* **PDF_FILE_AP** and, optionally, **PDF_FILE_ML**: name of the PDF file representing the implant, in the same directory as the TXT file, including the file extension and matching capitalization
* **ORIENTATION** values: *RIGHT*, *LEFT*, indicates the body-side for which the template is drawn for on the AP PDF
* **AP_HEAD_ROTATION_RADS**: a number, indicating by how many radiants the object is already rotated on the PDF (zero if the implant is displayed vertically)
* **LEFT_RIGHT** values: *RIGHT*, *LEFT*, *LEFT AND RIGHT*, *BOTH*, *Neutral*, specifies the body side the implant is for (if the value contains *RIGHT* then it's flagged as usable for the right side, if it contains *LEFT* it is flagged as usable for the left side; if it isn't flagged for neither right nor left, it is considered valid for both sides, so an empty field is ok for both, just like *LEFT AND RIGHT*, *BOTH* and *Neutral*)
* **OTHER_SIDE_REF_NO** is used in products that aren't body-side-neutral to specify the implant for the other side, by specifying that product's *REF_NO*
* **AP_ORIGIN_X** and **AP_ORIGIN_Y**: coordinates of the *origin* in the AP pdf (rotation point for cups, center  
for stems), in millimeters from the bottom-left corner of the PDF
* **AP_HEAD_ROTATION_POINT_1_X**, **AP_HEAD_ROTATION_POINT_1_Y** ... **AP_HEAD_ROTATION_POINT_6_X**, **AP_HEAD_ROTATION_POINT_6_Y**: coordinates of the rotation points (fixed points common between stem and cup) in millimeters from the described *ORIGIN* point (1 is interpreted as *XS*, 2 is *S*, then *M*, *L*, *XL* and *XXL*)


Additional values can be inserted and will be ignored: PART_INFO, NECK_ANGLE, OFFSET, CONE, CHANGE_TYPE, CHANGE_INFO, REPLACED_REF_NO, NOT_FOR_SALE_IN_TERRITORIES, DB_PART_NO, DB_PART_REV, TEMPLATE_GROUP, INFO_FILE, ...

## Rectangle of Interest

Out of a whole PDF, only the central part, where the implant is drawn, should be considered for overlay. You should specify the coordinates of the rectangle that bounds the region of interest using the plugin:

* prepare TXTs and PDFs, and inject them into the plugin
* launch the plugin, and view your templates one by one
* for every new template you will notice that no ROI is specified on the PDF. You should specify the ROI by pushing the Command key and dragging a rectangle around the interesting part of the PDF. Your rectangle will be slightly transformed by the plugin and saved
* once all your templates have their ROI, quit OsiriX and open the plugin's prefs PLIST at ~/Library/Preferences/com.osirix.hiparthroplastytemplating.plist; copy the interesting fields into a new plist and save it as _Bounds.plist, at the root of your Templates folder.

## Additional information

The plugin also supports proximal/distal stems, contact us if you want more  information about this.